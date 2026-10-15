/**
 * Governs any agent tool call with OpenBox, the way the other OpenBox SDKs govern tool calls.
 *
 * The agent's decision to call a tool is reported as ActivityStarted, with the tool name as
 * activity_type and its arguments as activity_input, inside the conversation's OpenBox session.
 * The tool runs only once OpenBox decides:
 *   ALLOW            run it now; ActivityCompleted reports the result (or the error)
 *   REQUIRE_APPROVAL nothing runs; the call waits as Pending_Approval until a human decides
 *   BLOCK            nothing runs; the refusal and reason go back to the agent
 *   HALT             nothing runs, and the conversation is ended
 * OpenBox unreachable, timed out or answering malformed: nothing runs.
 *
 * A tool is either an Apex executor (OpenBoxToolExecutor) or a registered flow, standard action
 * or invocable Apex class, run with Invocable.Action. Apex forbids callouts after DML, so a tool
 * that may write runs after the decision and its completion leaves through the outbox. A
 * read-only tool's completion is sent before the agent sees the result, so OpenBox output
 * guardrails can redact or withhold it.
 *
 * Approval: an approved call is resumed in a later transaction by the approval poller (Apex
 * executors) or by the agent checking on it (flows and actions, which must run as the agent's
 * own user). Only a Pending_Approval or Approved call can run, under a row lock, and it leaves that
 * status in the same transaction, so a call runs at most once.
 *
 * Runs without sharing: it writes integration records on behalf of the agent and is resumed by
 * background jobs. The tool itself enforces its own data access.
 */
public without sharing class OpenBoxToolGovernance {
    public static final String TARGET_APEX_EXECUTOR = 'apex_executor';
    public static final String TARGET_APEX = 'apex';
    public static final String TARGET_FLOW = 'flow';
    public static final String TARGET_STANDARD = 'standard';

    public static final String STATUS_APPROVED = 'Approved';

    private static final Integer MAX_LOG_CHARS = 131072;

    public class ToolCall {
        public String sessionKey;
        public String toolName;
        public Map<String, Object> input = new Map<String, Object>();
        public String targetType;
        public String targetName;
        /** Read-only tools change no data; their result passes OpenBox output guardrails first. */
        public Boolean readOnly = false;
        /** Optional: an executor instance. Otherwise one is built from targetName. */
        public OpenBoxToolExecutor executor;
    }

    public class Result {
        public String sessionKey;
        public String requestId;
        public String requestNumber;
        public String toolName;
        public String status;
        public String verdict;
        public String reason;
        public String message;
        public Boolean executed = false;
        public Map<String, Object> output;
        public Datetime approvalExpiresAt;

        public String outputJson() {
            return output == null ? null : JSON.serialize(output);
        }
    }

    private class Call {
        final OpenBox_Governed_Request__c record;
        final Result result = new Result();
        final List<OpenBox_Governance_Audit__c> audits = new List<OpenBox_Governance_Audit__c>();
        OpenBoxAgentSession session;
        OpenBoxGovernedRun run;
        OpenBoxGovernedRun.Activity activity;
        OpenBoxToolExecutor executor;
        Boolean readOnly = false;

        Call(OpenBox_Governed_Request__c record) {
            this.record = record;
            result.requestId = record.Request_Id__c;
            result.requestNumber = record.Name;
            result.toolName = record.Tool_Name__c;
            result.status = record.Status__c;
            result.verdict = record.Decision__c;
            result.reason = record.Reason__c;
            result.approvalExpiresAt = record.Approval_Expires_At__c;
        }

        void conclude(String status, String reason, String message) {
            record.Status__c = status;
            if (reason != null) {
                record.Reason__c = reason.abbreviate(4000);
            }
            result.status = status;
            result.reason = record.Reason__c;
            result.message = message;
        }

        void audit(String stage, String outcome, OpenBoxEvaluationResult decision, Map<String, Object> detail) {
            OpenBox_Governance_Audit__c entry = OpenBoxAudit.entry(
                record.Request_Id__c,
                stage,
                outcome,
                decision,
                null,
                record.Requested_By__c,
                detail
            );
            entry.Action__c = record.Tool_Name__c == null ? null : record.Tool_Name__c.abbreviate(80);
            audits.add(entry);
        }
    }

    private final OpenBoxSettings settings;
    private final OpenBoxClient client;

    public OpenBoxToolGovernance() {
        this(OpenBoxSettings.get(), new OpenBoxClient());
    }

    @TestVisible
    private OpenBoxToolGovernance(OpenBoxSettings settings, OpenBoxClient client) {
        this.settings = settings;
        this.client = client;
    }

    // ── New calls ───────────────────────────────────────────────────────────────────────────

    public Result govern(ToolCall toolCall) {
        if (toolCall == null || String.isBlank(toolCall.toolName)) {
            throw new OpenBoxContractException('A governed tool call needs a tool name');
        }
        OpenBox_Governed_Request__c record = new OpenBox_Governed_Request__c(
            Request_Id__c = OpenBoxIds.newRequestId(),
            Action__c = toolCall.toolName.abbreviate(80),
            Tool_Name__c = toolCall.toolName.abbreviate(255),
            Tool_Input__c = JSON.serialize(toolCall.input == null ? new Map<String, Object>() : toolCall.input)
                .abbreviate(MAX_LOG_CHARS),
            Target_Type__c = toolCall.targetType,
            Target_Name__c = toolCall.targetName,
            Requested_By__c = UserInfo.getUserId(),
            Status__c = OpenBoxDiscountGovernance.STATUS_AUTHORIZING,
            Next_Event_Sequence__c = 0,
            Poll_Count__c = 0
        );
        Call call = new Call(record);
        call.readOnly = toolCall.readOnly == true;
        call.executor = toolCall.executor;
        call.session = OpenBoxAgentSession.load(toolCall.sessionKey, true);
        call.result.sessionKey = call.session.key();
        Map<String, Object> input = toolCall.input == null ? new Map<String, Object>() : toolCall.input;

        if (call.session.isHalted()) {
            call.conclude(
                OpenBoxDiscountGovernance.STATUS_HALTED,
                'OpenBox ended this conversation earlier',
                'OpenBox ended this conversation, so nothing more can run in it. Please start a new conversation.'
            );
            call.audit(OpenBoxAudit.STAGE_AUTHORIZATION, 'Halted', null, null);
            commitCalls(new List<Call>{ call }, true);
            return call.result;
        }

        try {
            call.run = call.session.join(client, settings, 'Run the ' + toolCall.toolName + ' tool');
            record.Workflow_Id__c = call.session.record.Workflow_Id__c;
            record.Run_Id__c = call.session.record.Run_Id__c;
            record.Trace_Id__c = call.run.traceId;
            if (call.run.isHalted()) {
                halt(call, null, 'Session halted by OpenBox at start');
            } else {
                call.activity = call.run.newActivity(toolCall.toolName);
                record.Activity_Id__c = call.activity.activityId;
                OpenBoxEvaluationResult decision = call.run.startActivity(call.activity, input);
                recordDecision(call, decision);
                switch on decision.verdict {
                    when ALLOW {
                        call.audit(OpenBoxAudit.STAGE_AUTHORIZATION, 'Allowed', decision, null);
                        execute(call, input, false);
                    }
                    when REQUIRE_APPROVAL {
                        pend(call, decision);
                    }
                    when HALT {
                        halt(call, decision, decision.reason);
                    }
                    when else {
                        String reason = reasonOf(decision);
                        call.run.failActivity(call.activity, 'GovernanceBlocked', reason, null);
                        call.conclude(
                            OpenBoxDiscountGovernance.STATUS_BLOCKED,
                            reason,
                            'OpenBox blocked the ' + toolCall.toolName + ' tool: ' + reason + '. Nothing was run.'
                        );
                        call.audit(OpenBoxAudit.STAGE_AUTHORIZATION, 'Blocked', decision, null);
                    }
                }
            }
        } catch (OpenBoxException e) {
            failClosed(call, e);
        }
        commitCalls(new List<Call>{ call }, true);
        return call.result;
    }

    // ── Approved calls ──────────────────────────────────────────────────────────────────────

    /**
     * Resolves waiting calls: polls OpenBox for pending ones, closes rejected or expired ones, and
     * runs approved ones. runAsAgent is true when the agent's own user is checking on its calls;
     * flows and actions run only then, while Apex executors may also run from the background poller.
     * At most one call runs per transaction (a tool may write, and Apex allows no callout after a
     * write); other approved calls stay Approved for the next check.
     */
    public List<Result> resolve(Set<Id> requestIds, Boolean runAsAgent) {
        List<Call> calls = new List<Call>();
        for (OpenBox_Governed_Request__c record : [
            SELECT
                Id,
                Name,
                Request_Id__c,
                Tool_Name__c,
                Tool_Input__c,
                Target_Type__c,
                Target_Name__c,
                Status__c,
                Decision__c,
                Decision_Id__c,
                Reason__c,
                Workflow_Id__c,
                Run_Id__c,
                Activity_Id__c,
                Trace_Id__c,
                Requested_By__c,
                Approval_Expires_At__c,
                Poll_Count__c,
                Next_Event_Sequence__c,
                Agent_Session__c,
                Agent_Session__r.Session_Key__c,
                Agent_Session__r.Status__c,
                CreatedDate
            FROM OpenBox_Governed_Request__c
            WHERE
                Id IN :requestIds
                AND Tool_Name__c != NULL
                AND Status__c IN (:OpenBoxDiscountGovernance.STATUS_PENDING, :STATUS_APPROVED)
            FOR UPDATE
        ]) {
            if (calls.size() >= settings.maxRequestsPerTransaction) {
                break;
            }
            calls.add(new Call(record));
        }

        // Decide phase: every callout first.
        List<Call> runnable = new List<Call>();
        for (Call call : calls) {
            OpenBox_Governed_Request__c record = call.record;
            call.result.sessionKey = record.Agent_Session__r?.Session_Key__c;
            call.run = OpenBoxGovernedRun.attach(client, identityOf(record), record.Trace_Id__c, record.CreatedDate);
            call.activity = call.run.resumeActivity(record.Activity_Id__c, record.Tool_Name__c, record.CreatedDate);
            if (record.Agent_Session__r?.Status__c == OpenBoxAgentSession.STATUS_HALTED) {
                call.conclude(
                    OpenBoxDiscountGovernance.STATUS_HALTED,
                    'OpenBox ended this conversation before the call could run',
                    'OpenBox ended this conversation, so the ' + record.Tool_Name__c + ' tool was not run.'
                );
                call.audit(OpenBoxAudit.STAGE_APPROVAL, 'Halted', null, null);
                continue;
            }
            if (record.Status__c == OpenBoxDiscountGovernance.STATUS_PENDING) {
                poll(call);
            }
            if (call.record.Status__c == STATUS_APPROVED) {
                if (canRunHere(record, runAsAgent)) {
                    runnable.add(call);
                } else {
                    call.result.message =
                        'A human approved the ' +
                        record.Tool_Name__c +
                        ' tool (request ' +
                        record.Name +
                        '). Ask the agent to check on this request to run it.';
                }
            }
        }

        // Commit phase: at most one tool runs, then everything is written.
        if (!runnable.isEmpty()) {
            Call call = runnable[0];
            Map<String, Object> input = String.isBlank(call.record.Tool_Input__c)
                ? new Map<String, Object>()
                : (Map<String, Object>) JSON.deserializeUntyped(call.record.Tool_Input__c);
            execute(call, input, true);
            for (Integer i = 1; i < runnable.size(); i++) {
                runnable[i].result.message =
                    'Approved; the ' + runnable[i].record.Tool_Name__c + ' tool will run on the next check.';
            }
        }
        closeFinishedTurns(calls);
        commitCalls(calls, false);
        return results(calls);
    }

    /**
     * A turn that ended while a call was waiting for a human was left open; once its last waiting
     * call is resolved, the turn's run is closed with WorkflowCompleted (queued in the outbox).
     */
    private static void closeFinishedTurns(List<Call> calls) {
        Set<Id> resolved = new Set<Id>();
        for (Call call : calls) {
            if (!isWaiting(call.record.Status__c)) {
                resolved.add(call.record.Id);
            }
        }
        Set<String> closedRuns = new Set<String>();
        for (Call call : calls) {
            OpenBox_Governed_Request__c record = call.record;
            if (
                call.run == null ||
                isWaiting(record.Status__c) ||
                closedRuns.contains(record.Run_Id__c) ||
                !OpenBoxAgentSession.runIsOver(record.Agent_Session__c, record.Run_Id__c, resolved)
            ) {
                continue;
            }
            Boolean succeeded = record.Status__c == OpenBoxDiscountGovernance.STATUS_EXECUTED;
            call.run.deferRemainingEvents();
            call.run.endConversation(succeeded, null, succeeded ? null : record.Status__c, succeeded ? null : record.Reason__c);
            closedRuns.add(record.Run_Id__c);
        }
    }

    private static Boolean isWaiting(String status) {
        return status == OpenBoxDiscountGovernance.STATUS_PENDING || status == STATUS_APPROVED;
    }

    private void poll(Call call) {
        OpenBox_Governed_Request__c record = call.record;
        record.Last_Polled_At__c = Datetime.now();
        record.Poll_Count__c = (record.Poll_Count__c == null ? 0 : record.Poll_Count__c) + 1;
        OpenBoxApprovalResult approval;
        try {
            approval = client.pollApproval(record.Workflow_Id__c, record.Run_Id__c, record.Activity_Id__c);
        } catch (OpenBoxException e) {
            // An unreachable OpenBox decides nothing; the next poll asks again.
            record.Error__c = ('Approval poll failed: ' + e.getMessage()).abbreviate(4000);
            call.result.message = pendingMessage(record, record.Name);
            return;
        }
        record.Error__c = null;
        if (approval.expiresAt != null) {
            record.Approval_Expires_At__c = approval.expiresAt;
            call.result.approvalExpiresAt = approval.expiresAt;
        }
        Map<String, Object> detail = new Map<String, Object>{
            'approval_status' => approval.status.name(),
            'approval_reason' => approval.reason,
            'approval_event_id' => approval.governanceEventId
        };
        switch on approval.status {
            when PENDING {
                call.result.message = pendingMessage(record, record.Name);
            }
            when APPROVED {
                record.Decided_At__c = Datetime.now();
                record.Status__c = STATUS_APPROVED;
                call.result.status = STATUS_APPROVED;
                call.audit(OpenBoxAudit.STAGE_APPROVAL, 'Approved', null, detail);
            }
            when REJECTED, EXPIRED {
                Boolean rejected = approval.status == OpenBoxApprovalResult.State.REJECTED;
                String reason = String.isBlank(approval.reason)
                    ? (rejected ? 'Approval rejected' : 'Approval expired')
                    : approval.reason;
                record.Decided_At__c = Datetime.now();
                call.run.failActivity(call.activity, rejected ? 'ApprovalRejected' : 'ApprovalExpired', reason, null);
                call.conclude(
                    rejected ? OpenBoxDiscountGovernance.STATUS_REJECTED : OpenBoxDiscountGovernance.STATUS_EXPIRED,
                    reason,
                    'The ' + record.Tool_Name__c + ' tool was ' + (rejected ? 'rejected' : 'not approved in time') +
                    ': ' + reason + '. Nothing was run.'
                );
                call.audit(OpenBoxAudit.STAGE_APPROVAL, rejected ? 'Rejected' : 'Expired', null, detail);
            }
        }
    }

    private static Boolean canRunHere(OpenBox_Governed_Request__c record, Boolean runAsAgent) {
        if (record.Target_Type__c == TARGET_APEX_EXECUTOR) {
            return true;
        }
        // Flows and actions run as the user who asked, never as the background job's user.
        return runAsAgent == true && record.Requested_By__c == UserInfo.getUserId();
    }

    // ── Shared execution ────────────────────────────────────────────────────────────────────

    /**
     * Runs an authorized call. A read-only tool's completion is decided before its result is
     * returned (output guardrails); anything else is deferred to the outbox, because the tool may
     * have written data and no callout can follow.
     */
    private void execute(Call call, Map<String, Object> input, Boolean resumed) {
        OpenBox_Governed_Request__c record = call.record;
        Boolean readOnly = call.readOnly && !resumed;
        if (!readOnly) {
            call.run.deferRemainingEvents();
        }
        OpenBoxToolContext context = new OpenBoxToolContext(
            record.Requested_By__c,
            call.result.sessionKey,
            record.Request_Id__c,
            resumed
        );
        Savepoint savepoint = readOnly ? null : Database.setSavepoint();
        Map<String, Object> output;
        try {
            output = invoke(call, record, input, context);
        } catch (Exception e) {
            if (savepoint != null) {
                Database.rollback(savepoint);
            }
            String error = e.getTypeName() + ': ' + e.getMessage();
            call.run.failActivity(call.activity, 'ToolFailed', error, null);
            record.Error__c = error.abbreviate(4000);
            call.conclude(
                OpenBoxDiscountGovernance.STATUS_FAILED,
                error,
                'OpenBox allowed the ' + record.Tool_Name__c + ' tool, but it failed: ' + e.getMessage()
            );
            call.audit(OpenBoxAudit.STAGE_EXECUTION, 'Tool_Failed', null, new Map<String, Object>{ 'error' => error });
            return;
        }

        OpenBoxEvaluationResult completed = call.run.completeActivity(call.activity, output);
        if (completed != null && (completed.verdict == OpenBoxVerdict.BLOCK || completed.verdict == OpenBoxVerdict.HALT)) {
            // Output guardrails refused the result: the tool ran, but the agent does not see it.
            recordDecision(call, completed);
            if (completed.verdict == OpenBoxVerdict.HALT) {
                call.session?.markHalted();
            }
            call.conclude(
                OpenBoxDiscountGovernance.STATUS_BLOCKED,
                reasonOf(completed),
                'OpenBox withheld the result of the ' + record.Tool_Name__c + ' tool: ' + reasonOf(completed) + '.'
            );
            call.audit(OpenBoxAudit.STAGE_EXECUTION, 'Output_Withheld', completed, null);
            return;
        }
        if (completed != null && output != null) {
            for (String field : output.keySet()) {
                Object redacted = completed.redactedInputField(field);
                if (redacted != null) {
                    output.put(field, redacted);
                }
            }
        }
        record.Tool_Output__c = output == null ? null : JSON.serialize(output).abbreviate(MAX_LOG_CHARS);
        record.Executed_At__c = Datetime.now();
        call.result.executed = true;
        call.result.output = output;
        call.conclude(
            OpenBoxDiscountGovernance.STATUS_EXECUTED,
            null,
            'The ' + record.Tool_Name__c + ' tool ran' + (resumed ? ' after approval.' : '.')
        );
        call.audit(OpenBoxAudit.STAGE_EXECUTION, 'Executed', null, null);
    }

    private static Map<String, Object> invoke(
        Call call,
        OpenBox_Governed_Request__c record,
        Map<String, Object> input,
        OpenBoxToolContext context
    ) {
        if (record.Target_Type__c == TARGET_APEX_EXECUTOR) {
            OpenBoxToolExecutor executor = call.executor;
            if (executor == null) {
                Type executorType = String.isBlank(record.Target_Name__c) ? null : Type.forName(record.Target_Name__c);
                Object instance = executorType == null ? null : executorType.newInstance();
                if (!(instance instanceof OpenBoxToolExecutor)) {
                    throw new OpenBoxContractException(
                        record.Target_Name__c + ' is not an OpenBoxToolExecutor with a no-argument constructor'
                    );
                }
                executor = (OpenBoxToolExecutor) instance;
            }
            return executor.execute(context, input);
        }

        Invocable.Action action;
        if (record.Target_Type__c == TARGET_STANDARD) {
            action = Invocable.Action.createStandardAction(record.Target_Name__c);
        } else if (record.Target_Type__c == TARGET_FLOW || record.Target_Type__c == TARGET_APEX) {
            action = Invocable.Action.createCustomAction(record.Target_Type__c, record.Target_Name__c);
        } else {
            throw new OpenBoxContractException('Unsupported tool target type: ' + record.Target_Type__c);
        }
        for (String name : input.keySet()) {
            action.setInvocationParameter(name, input.get(name));
        }
        List<Invocable.Action.Result> results = action.invoke();
        if (results.isEmpty()) {
            return new Map<String, Object>();
        }
        Invocable.Action.Result outcome = results[0];
        if (!outcome.isSuccess()) {
            List<String> messages = new List<String>();
            for (Invocable.Action.Error error : outcome.getErrors()) {
                messages.add(error.getMessage());
            }
            throw new OpenBoxToolException(String.join(messages, '; '));
        }
        Map<String, Object> output = outcome.getOutputParameters();
        return output == null ? new Map<String, Object>() : new Map<String, Object>(output);
    }

    private void pend(Call call, OpenBoxEvaluationResult decision) {
        OpenBox_Governed_Request__c record = call.record;
        record.Approval_Expires_At__c = decision.approvalExpiresAt;
        call.result.approvalExpiresAt = decision.approvalExpiresAt;
        record.Status__c = OpenBoxDiscountGovernance.STATUS_PENDING;
        call.result.status = record.Status__c;
        call.audit(OpenBoxAudit.STAGE_AUTHORIZATION, 'Approval_Required', decision, null);
    }

    private void halt(Call call, OpenBoxEvaluationResult decision, String reason) {
        String why = String.isBlank(reason) ? 'Halted by OpenBox' : reason;
        call.session.markHalted();
        call.run.finish(false, null, 'halt', why);
        call.conclude(
            OpenBoxDiscountGovernance.STATUS_HALTED,
            why,
            'OpenBox ended this conversation: ' + why + '. Nothing was run.'
        );
        call.audit(OpenBoxAudit.STAGE_AUTHORIZATION, 'Halted', decision, null);
    }

    private void failClosed(Call call, OpenBoxException failure) {
        String reason = 'OpenBox governance unavailable: ' + failure.getMessage();
        if (call.run != null && call.activity != null && !call.activity.isClosed()) {
            call.run.failActivity(call.activity, failure.getTypeName(), failure.getMessage(), null);
        }
        call.record.Error__c = reason.abbreviate(4000);
        call.record.Decision__c = call.record.Decision__c == null ? OpenBoxTurnGovernance.VERDICT_ERROR : call.record.Decision__c;
        call.result.verdict = call.record.Decision__c;
        call.conclude(
            OpenBoxDiscountGovernance.STATUS_FAILED,
            reason,
            'The ' + call.record.Tool_Name__c + ' tool was not run because OpenBox could not authorize it. Try again later.'
        );
        call.audit(OpenBoxAudit.STAGE_AUTHORIZATION, 'Governance_Unavailable', null, new Map<String, Object>{ 'error' => failure.getMessage() });
    }

    private static void recordDecision(Call call, OpenBoxEvaluationResult decision) {
        call.record.Decision__c = decision.verdict.name();
        call.record.Decision_Id__c = decision.governanceEventId;
        call.record.Policy_Id__c = decision.policyId;
        call.record.Reason__c = decision.reason == null ? null : decision.reason.abbreviate(4000);
        call.result.verdict = call.record.Decision__c;
        call.result.reason = call.record.Reason__c;
    }

    // ── Commit phase ────────────────────────────────────────────────────────────────────────

    private void commitCalls(List<Call> calls, Boolean saveSessions) {
        if (calls.isEmpty()) {
            return;
        }
        List<OpenBox_Governed_Request__c> records = new List<OpenBox_Governed_Request__c>();
        for (Call call : calls) {
            if (saveSessions && call.session != null) {
                call.session.save();
                call.record.Agent_Session__c = call.session.record.Id;
            }
            records.add(call.record);
        }
        upsert records;

        List<OpenBox_Event_Outbox__c> outbox = new List<OpenBox_Event_Outbox__c>();
        List<OpenBox_Governance_Audit__c> audits = new List<OpenBox_Governance_Audit__c>();
        Map<String, Id> requestIds = new Map<String, Id>();
        Boolean pending = false;
        for (Call call : calls) {
            requestIds.put(call.record.Request_Id__c, call.record.Id);
            for (OpenBox_Governance_Audit__c entry : call.audits) {
                entry.Agent_Session__c = call.record.Agent_Session__c;
                audits.add(entry);
            }
            if (call.run != null) {
                outbox.addAll(OpenBoxOutbox.stage(call.record, call.run.drainDeferredEvents()));
                for (String failure : call.run.telemetryFailures()) {
                    OpenBox_Governance_Audit__c entry = OpenBoxAudit.entry(
                        call.record.Request_Id__c,
                        OpenBoxAudit.STAGE_TELEMETRY,
                        'Governance_Unavailable',
                        null,
                        null,
                        call.record.Requested_By__c,
                        new Map<String, Object>{ 'queued_for_retry' => failure }
                    );
                    entry.Agent_Session__c = call.record.Agent_Session__c;
                    audits.add(entry);
                }
            }
            pending |= call.record.Status__c == OpenBoxDiscountGovernance.STATUS_PENDING ||
                (call.record.Status__c == STATUS_APPROVED && call.record.Target_Type__c == TARGET_APEX_EXECUTOR);
        }
        update records;
        OpenBoxAudit.link(audits, requestIds);
        insert audits;
        insert outbox;
        if (!outbox.isEmpty()) {
            OpenBoxOutboxDispatcher.ensureScheduled();
        }
        if (pending) {
            OpenBoxApprovalPoller.ensureScheduled();
        }

        Map<Id, Call> byId = new Map<Id, Call>();
        for (Call call : calls) {
            byId.put(call.record.Id, call);
        }
        for (OpenBox_Governed_Request__c row : [SELECT Id, Name FROM OpenBox_Governed_Request__c WHERE Id IN :byId.keySet()]) {
            Call call = byId.get(row.Id);
            call.result.requestNumber = row.Name;
            if (call.record.Status__c == OpenBoxDiscountGovernance.STATUS_PENDING) {
                call.result.message = pendingMessage(call.record, row.Name);
            }
        }
    }

    // ── Helpers ─────────────────────────────────────────────────────────────────────────────

    private OpenBoxEvents.Identity identityOf(OpenBox_Governed_Request__c record) {
        return new OpenBoxEvents.Identity(
            record.Workflow_Id__c,
            record.Run_Id__c,
            settings.workflowType,
            settings.taskQueue,
            settings.agentName,
            record.Agent_Session__r?.Session_Key__c
        );
    }

    private static String pendingMessage(OpenBox_Governed_Request__c record, String requestNumber) {
        String next = record.Target_Type__c == TARGET_APEX_EXECUTOR
            ? 'it will run automatically if approved'
            : 'once approved, ask me to check request ' + requestNumber + ' and I will run it';
        String message =
            'The ' +
            record.Tool_Name__c +
            ' tool needs human approval in OpenBox (request ' +
            requestNumber +
            '). Nothing has run yet; ' +
            next;
        if (record.Approval_Expires_At__c != null) {
            message += '. The approval lapses at ' + record.Approval_Expires_At__c.formatGmt('yyyy-MM-dd HH:mm') + ' UTC';
        }
        return message + '.';
    }

    private static String reasonOf(OpenBoxEvaluationResult decision) {
        return String.isBlank(decision.reason) ? 'Refused by OpenBox policy' : decision.reason;
    }

    private static List<Result> results(List<Call> calls) {
        List<Result> results = new List<Result>();
        for (Call call : calls) {
            results.add(call.result);
        }
        return results;
    }

    public class OpenBoxToolException extends Exception {
    }
}
