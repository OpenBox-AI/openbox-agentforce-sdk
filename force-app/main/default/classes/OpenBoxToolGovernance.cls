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
 * A tool is an Apex executor (OpenBoxToolExecutor), a registered flow, standard action or
 * invocable Apex class (run with Invocable.Action), or a record write (OpenBoxRecordWriter). A
 * record write gets the full write protocol: a governed lookup, policy facts from the record, a
 * locked re-read, a staleness check, Salesforce access for the requesting user and behaviour-rule
 * spans before one system-mode update made past the field guard (see OpenBoxRecordWriter). A
 * record write outside any conversation is an OpenBox run of its own.
 *
 * Apex forbids callouts after DML, so every call of a transaction is decided first (callouts and
 * queries only), read-only tools then run with their output passing OpenBox output guardrails,
 * record writes are prepared, and only then does anything write: tools that may write, the record
 * updates, and the governance records. Events after the first write leave through the outbox.
 *
 * Approval: an approved call is resumed in a later transaction by the approval poller (Apex
 * executors and record writes) or by the agent checking on it (flows and actions, which must run
 * as the agent's own user). Only a Pending_Approval or Approved call can run, under a row lock,
 * and it leaves that status in the same transaction, so a call runs at most once.
 *
 * Runs without sharing: it writes integration records on behalf of the agent and is resumed by
 * background jobs. Tools enforce their own data access; record writes are checked for the
 * requesting user by OpenBoxAccess immediately before the write.
 */
public without sharing class OpenBoxToolGovernance {
    public static final String TARGET_APEX_EXECUTOR = 'apex_executor';
    public static final String TARGET_APEX = 'apex';
    public static final String TARGET_FLOW = 'flow';
    public static final String TARGET_STANDARD = 'standard';
    public static final String TARGET_RECORD_WRITER = 'record_writer';

    // Upper bounds of what one governed record write consumes, checked before OpenBox is contacted.
    @TestVisible
    private static final Integer CALLOUTS_PER_WRITE = 12;
    @TestVisible
    private static final Integer CPU_MS_PER_WRITE = 3000;
    private static final Integer MAX_LOG_CHARS = 131072;
    private static final Integer MAX_JUSTIFICATION_CHARS = 2000;
    private static final Integer MAX_PROMPT_CHARS = 4000;

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
        /** A record write: the OpenBoxRecordWriter class. Sets the target type and name. */
        public Type writer;
        /** The name recorded on the request and its audit trail. Defaults to the tool name. */
        public String action;
        /** The user's message, verbatim: the goal of a run this call starts, and its user prompt. */
        public String userPrompt;
        /** Why, in the user's words. Stored after OpenBox input guardrails have redacted it. */
        public String justification;
    }

    public class Result {
        public String sessionKey;
        public String requestId;
        public String requestNumber;
        public String toolName;
        public String status;
        public String verdict;
        public String decisionId;
        public String reason;
        public String message;
        public Boolean executed = false;
        public Map<String, Object> output;
        public Datetime approvalExpiresAt;
        /** Record writes: the record, the change asked for, its values before it, and what the agent may say about it. */
        public Id recordId;
        public Map<String, Object> changes;
        public Map<String, Object> previousValues;
        public String summary;

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
        OpenBoxRecordWriter writer;
        Map<String, Object> input = new Map<String, Object>();
        Boolean readOnly = false;
        // A record write outside any conversation: the call is an OpenBox run of its own.
        Boolean standalone = false;
        Boolean resumed = false;
        // Authorized and due to run in this transaction.
        Boolean runNow = false;
        // Record writes: the change, the record as re-read under lock, and the prepared update.
        Map<String, Object> changes;
        SObject current;
        SObject pendingWrite;
        OpenBoxSpan updateSpan;

        Call(OpenBox_Governed_Request__c record) {
            this.record = record;
            result.requestId = record.Request_Id__c;
            result.requestNumber = record.Name;
            result.toolName = record.Tool_Name__c;
            result.status = record.Status__c;
            result.verdict = record.Decision__c;
            result.decisionId = record.Decision_Id__c;
            result.reason = record.Reason__c;
            result.approvalExpiresAt = record.Approval_Expires_At__c;
            result.recordId = record.Record_Id__c;
            if (String.isNotBlank(record.Baseline_Values__c)) {
                result.previousValues = (Map<String, Object>) JSON.deserializeUntyped(record.Baseline_Values__c);
            }
        }

        Boolean isWrite() {
            return writer != null;
        }

        /** How the call is named in messages: "the discount change", "the find_opportunity tool". */
        String subject() {
            return 'the ' + (isWrite() ? writer.changeLabel() : record.Tool_Name__c + ' tool');
        }

        String verb() {
            return isWrite() ? 'applied' : 'run';
        }

        String nothingDone() {
            return isWrite() ? 'Nothing was changed.' : 'Nothing was run.';
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
                record.Record_Id__c,
                record.Requested_By__c,
                detail
            );
            entry.Action__c = record.Action__c;
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
        return governAll(new List<ToolCall>{ toolCall })[0];
    }

    /**
     * Governs several calls in one transaction: all are decided before any of them writes.
     * Results are returned in call order. Calls beyond the per-transaction limit are refused.
     */
    public List<Result> governAll(List<ToolCall> toolCalls) {
        List<Call> calls = new List<Call>();
        Map<String, OpenBoxAgentSession> sessions = new Map<String, OpenBoxAgentSession>();
        for (Integer i = 0; i < toolCalls.size(); i++) {
            Call call = newCall(toolCalls[i]);
            calls.add(call);
            if (i >= settings.maxRequestsPerTransaction) {
                rejectInvalid(call, 'At most ' + settings.maxRequestsPerTransaction + ' governed calls are made per transaction');
                continue;
            }
            decide(call, toolCalls[i], sessions);
        }
        run(calls);
        commitCalls(calls);
        return results(calls);
    }

    private Call newCall(ToolCall toolCall) {
        if (toolCall == null || String.isBlank(toolCall.toolName)) {
            throw new OpenBoxContractException('A governed tool call needs a tool name');
        }
        Map<String, Object> input = toolCall.input == null ? new Map<String, Object>() : toolCall.input;
        String targetType = toolCall.writer == null ? toolCall.targetType : TARGET_RECORD_WRITER;
        String targetName = toolCall.writer == null ? toolCall.targetName : toolCall.writer.getName();
        String action = String.isBlank(toolCall.action) ? toolCall.toolName : toolCall.action;
        OpenBox_Governed_Request__c record = new OpenBox_Governed_Request__c(
            Request_Id__c = OpenBoxIds.newRequestId(),
            Action__c = action.abbreviate(80),
            Tool_Name__c = toolCall.toolName.abbreviate(255),
            Tool_Input__c = JSON.serialize(input).abbreviate(MAX_LOG_CHARS),
            Target_Type__c = targetType,
            Target_Name__c = targetName,
            Requested_By__c = UserInfo.getUserId(),
            Agent_Session_Id__c = toolCall.sessionKey == null ? null : toolCall.sessionKey.trim().abbreviate(255),
            Justification__c = toolCall.justification == null ? null : toolCall.justification.abbreviate(4000),
            Status__c = OpenBoxRequestStatus.AUTHORIZING,
            Next_Event_Sequence__c = 0,
            Poll_Count__c = 0
        );
        Call call = new Call(record);
        call.input = input;
        call.result.sessionKey = record.Agent_Session_Id__c;
        call.readOnly = toolCall.readOnly == true && toolCall.writer == null;
        call.executor = toolCall.executor;
        if (toolCall.writer != null) {
            call.writer = newWriter(targetName);
        }
        return call;
    }

    private void decide(Call call, ToolCall toolCall, Map<String, OpenBoxAgentSession> sessions) {
        if (call.isWrite() && !preflight(call)) {
            return;
        }
        String key = String.isBlank(toolCall.sessionKey) ? null : toolCall.sessionKey.trim();
        call.session = key == null ? null : sessions.get(key);
        if (call.session == null) {
            // A record write joins its conversation when it is part of one and runs on its own
            // otherwise; any other tool call starts a conversation when it has none.
            call.session = call.isWrite() ? OpenBoxAgentSession.findExisting(key) : OpenBoxAgentSession.load(key, true);
            if (call.session != null && key != null) {
                sessions.put(key, call.session);
            }
        }
        call.standalone = call.session == null;
        call.result.sessionKey = call.standalone ? key : call.session.key();

        if (!call.standalone && call.session.isHalted()) {
            call.conclude(
                OpenBoxRequestStatus.HALTED,
                'OpenBox ended this conversation earlier',
                'OpenBox ended this conversation, so nothing more can run in it. Please start a new conversation.'
            );
            call.audit(OpenBoxAudit.STAGE_AUTHORIZATION, 'Halted', null, null);
            return;
        }

        String goal = String.isNotBlank(toolCall.userPrompt)
            ? toolCall.userPrompt.abbreviate(MAX_PROMPT_CHARS)
            : 'Run the ' + toolCall.toolName + ' tool';
        try {
            startRun(call, goal, toolCall.userPrompt);
            if (call.run.isHalted()) {
                halt(call, null, 'Session halted by OpenBox at start');
                return;
            }
            if (call.isWrite()) {
                SObject current = lookup(call);
                if (current != null) {
                    decideWrite(call, current);
                }
            } else {
                decideTool(call);
            }
        } catch (OpenBoxException e) {
            failClosed(call, e);
        }
    }

    private void startRun(Call call, String goal, String userPrompt) {
        OpenBox_Governed_Request__c record = call.record;
        if (!call.standalone) {
            call.run = call.session.join(client, settings, goal);
            record.Workflow_Id__c = call.session.record.Workflow_Id__c;
            record.Run_Id__c = call.session.record.Run_Id__c;
        } else {
            OpenBoxEvents.Identity identity = new OpenBoxEvents.Identity(
                'salesforce-' + UserInfo.getOrganizationId() + '-' + record.Request_Id__c,
                record.Request_Id__c,
                settings.workflowType,
                settings.taskQueue,
                settings.agentName,
                record.Agent_Session_Id__c
            );
            record.Workflow_Id__c = identity.workflowId;
            record.Run_Id__c = identity.runId;
            call.run = OpenBoxGovernedRun.start(
                client,
                identity,
                new Map<String, Object>{
                    'request_id' => record.Request_Id__c,
                    'action' => record.Action__c,
                    'salesforce_org_id' => UserInfo.getOrganizationId(),
                    'record_id' => call.writer.recordId(call.input),
                    'requested_change' => call.writer.changes(call.input),
                    'actor_id' => record.Requested_By__c,
                    'agent_session_id' => record.Agent_Session_Id__c
                },
                goal
            );
            if (!call.run.isHalted() && String.isNotBlank(userPrompt)) {
                call.run.signalUserPrompt(userPrompt.abbreviate(MAX_PROMPT_CHARS));
            }
        }
        record.Trace_Id__c = call.run.traceId;
    }

    private void decideTool(Call call) {
        call.activity = call.run.newActivity(call.record.Tool_Name__c);
        call.record.Activity_Id__c = call.activity.activityId;
        OpenBoxEvaluationResult decision = call.run.startActivity(call.activity, call.input);
        recordDecision(call, decision);
        switch on decision.verdict {
            when ALLOW {
                call.audit(OpenBoxAudit.STAGE_AUTHORIZATION, 'Allowed', decision, null);
                call.runNow = true;
            }
            when REQUIRE_APPROVAL {
                pend(call, decision);
            }
            when HALT {
                halt(call, decision, decision.reason);
            }
            when else {
                block(call, call.activity, decision, OpenBoxAudit.STAGE_AUTHORIZATION);
            }
        }
    }

    // ── Record writes: decide ───────────────────────────────────────────────────────────────

    /** Validation, entitlement and capacity, before OpenBox is contacted. */
    private Boolean preflight(Call call) {
        OpenBoxRecordWriter writer = call.writer;
        Id recordId;
        String invalid;
        try {
            invalid = writer.validate(call.input);
            recordId = writer.recordId(call.input);
            if (invalid == null && (recordId == null || recordId.getSobjectType() != writer.objectType())) {
                invalid = 'The request does not name a ' + writer.objectType().getDescribe().getLabel() + ' record';
            }
            if (invalid == null) {
                call.changes = writer.changes(call.input);
                call.result.changes = call.changes;
            }
        } catch (Exception e) {
            invalid = e.getMessage();
        }
        if (invalid == null && (call.changes == null || call.changes.isEmpty())) {
            invalid = 'The request changes nothing';
        }
        if (invalid != null) {
            rejectInvalid(call, invalid);
            return false;
        }
        call.record.Record_Id__c = recordId;
        call.result.recordId = recordId;

        OpenBoxAccess.Decision entitlement = OpenBoxAccess.canRequest(call.record.Requested_By__c, writer.requiredPermission());
        if (!entitlement.allowed) {
            call.conclude(OpenBoxRequestStatus.PERMISSION_DENIED, entitlement.reason, 'Not permitted: ' + entitlement.reason + '.');
            call.audit(OpenBoxAudit.STAGE_AUTHORIZATION, 'Permission_Denied', null, null);
            return false;
        }
        if (OpenBoxClient.remainingCallouts() < CALLOUTS_PER_WRITE + OpenBoxWorkloadIdentity.pendingCallouts()) {
            rejectInvalid(call, 'Not enough callout capacity left in this transaction to govern the request');
            return false;
        }
        if (Limits.getLimitCpuTime() - Limits.getCpuTime() < CPU_MS_PER_WRITE) {
            rejectInvalid(call, 'Not enough processing capacity left in this transaction to govern the request');
            return false;
        }
        return true;
    }

    /**
     * The read activity. Its output is what the agent is told about the record, so output-stage
     * guardrails (for example personal-data redaction) apply before it leaves.
     */
    private SObject lookup(Call call) {
        OpenBoxRecordWriter writer = call.writer;
        Id recordId = call.record.Record_Id__c;
        OpenBoxGovernedRun.Activity activity = call.run.newActivity(writer.lookupActivityType());
        Map<String, Object> lookupInput = new Map<String, Object>{
            'request_id' => call.record.Request_Id__c,
            'salesforce_org_id' => UserInfo.getOrganizationId()
        };
        lookupInput.putAll(writer.lookupInput(recordId));
        OpenBoxEvaluationResult started = call.run.startActivity(activity, lookupInput);
        if (!started.isAllowed()) {
            stop(call, activity, started, OpenBoxAudit.STAGE_AUTHORIZATION);
            return null;
        }

        String query = selectStatement(call);
        OpenBoxSpan span = OpenBoxSpan.soqlSelect(
            call.run.traceId,
            null,
            objectName(writer),
            literalStatement(query, recordId),
            recordAttributes(writer, recordId)
        );
        OpenBoxEvaluationResult preflight = call.run.spanStarted(activity, span);
        if (!preflight.isAllowed()) {
            stop(call, activity, preflight, OpenBoxAudit.STAGE_AUTHORIZATION);
            return null;
        }

        List<SObject> rows;
        try {
            // The agent reads only what its own user may see.
            rows = Database.queryWithBinds(query + ' LIMIT 1', new Map<String, Object>{ 'recordId' => recordId }, AccessLevel.USER_MODE);
        } catch (QueryException e) {
            span.failed('QueryException', e.getMessage());
            call.run.spanCompleted(activity, span);
            call.run.failActivity(activity, 'PermissionDenied', e.getMessage(), null);
            finishStandalone(call, false, null, 'PermissionDenied', e.getMessage());
            call.conclude(
                OpenBoxRequestStatus.PERMISSION_DENIED,
                e.getMessage(),
                'Not permitted: the agent user cannot read this ' + writer.objectType().getDescribe().getLabel() + '.'
            );
            call.audit(OpenBoxAudit.STAGE_AUTHORIZATION, 'Permission_Denied', null, null);
            return null;
        }
        span.succeeded(rows.size());
        call.run.spanCompleted(activity, span);

        if (rows.isEmpty()) {
            String reason = writer.objectType().getDescribe().getLabel() + ' not found or not visible to the requesting user';
            call.run.failActivity(activity, 'RecordNotFound', reason, null);
            finishStandalone(call, false, null, 'RecordNotFound', reason);
            rejectInvalid(call, reason);
            return null;
        }

        SObject current = rows[0];
        Map<String, Object> snapshot = writer.snapshot(current);
        OpenBoxEvaluationResult completed = call.run.completeActivity(activity, snapshot);
        if (completed != null && (completed.verdict == OpenBoxVerdict.BLOCK || completed.verdict == OpenBoxVerdict.HALT)) {
            stop(call, null, completed, OpenBoxAudit.STAGE_AUTHORIZATION);
            return null;
        }
        Map<String, Object> redacted = snapshot.clone();
        if (completed != null) {
            for (String field : snapshot.keySet()) {
                Object value = completed.redactedInputField(field);
                if (value != null) {
                    redacted.put(field, value);
                }
            }
        }
        call.result.summary = writer.summary(current, redacted);
        return current;
    }

    private void decideWrite(Call call, SObject current) {
        OpenBox_Governed_Request__c record = call.record;
        Map<String, Object> previous = new Map<String, Object>();
        for (String field : call.changes.keySet()) {
            previous.put(field, current.get(field));
        }
        record.Baseline_Modstamp__c = (Datetime) current.get('SystemModstamp');
        record.Baseline_Values__c = JSON.serialize(previous).abbreviate(MAX_LOG_CHARS);
        call.result.previousValues = previous;

        call.activity = call.run.newActivity(record.Tool_Name__c);
        record.Activity_Id__c = call.activity.activityId;
        Map<String, Object> facts = new Map<String, Object>{
            'request_id' => record.Request_Id__c,
            'action' => record.Action__c,
            'salesforce_org_id' => UserInfo.getOrganizationId()
        };
        facts.putAll(call.writer.facts(current, call.input));
        facts.put('requested_change', call.changes);
        facts.put('justification', record.Justification__c == null ? null : record.Justification__c.abbreviate(MAX_JUSTIFICATION_CHARS));
        facts.put('actor_id', record.Requested_By__c);

        OpenBoxEvaluationResult decision = call.run.startActivity(call.activity, facts);
        recordDecision(call, decision);
        switch on decision.verdict {
            when ALLOW {
                call.audit(OpenBoxAudit.STAGE_AUTHORIZATION, 'Allowed', decision, null);
                call.runNow = true;
            }
            when REQUIRE_APPROVAL {
                pend(call, decision);
            }
            when else {
                stop(call, call.activity, decision, OpenBoxAudit.STAGE_AUTHORIZATION);
            }
        }
    }

    // ── Approved calls ──────────────────────────────────────────────────────────────────────

    /**
     * Resolves waiting calls: polls OpenBox for pending ones, closes rejected or expired ones, and
     * runs approved ones. runAsAgent is true when the agent's own user is checking on its calls;
     * flows and actions run only then, while Apex executors and record writes may also run from
     * the background poller. Every approved record write runs; at most one other tool runs per
     * transaction, and other approved ones stay Approved for the next check. Calls that are no
     * longer waiting are reported as they stand.
     */
    public List<Result> resolve(Set<Id> requestIds, Boolean runAsAgent) {
        List<Call> calls = new List<Call>();
        Set<Id> locked = new Set<Id>();
        for (OpenBox_Governed_Request__c record : [
            SELECT
                Id,
                Name,
                Request_Id__c,
                Action__c,
                Tool_Name__c,
                Tool_Input__c,
                Target_Type__c,
                Target_Name__c,
                Record_Id__c,
                Baseline_Modstamp__c,
                Baseline_Values__c,
                Justification__c,
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
                Agent_Session_Id__c,
                Agent_Session__c,
                Agent_Session__r.Session_Key__c,
                Agent_Session__r.Status__c,
                CreatedDate
            FROM OpenBox_Governed_Request__c
            WHERE Id IN :requestIds AND Status__c IN :OpenBoxRequestStatus.WAITING
            FOR UPDATE
        ]) {
            if (calls.size() >= settings.maxRequestsPerTransaction) {
                break;
            }
            calls.add(resumeCall(record));
            locked.add(record.Id);
        }

        // Decide phase: every callout first.
        Boolean toolChosen = false;
        for (Call call : calls) {
            OpenBox_Governed_Request__c record = call.record;
            if (record.Agent_Session__r?.Status__c == OpenBoxAgentSession.STATUS_HALTED) {
                record.Decided_At__c = Datetime.now();
                call.conclude(
                    OpenBoxRequestStatus.HALTED,
                    'OpenBox ended this conversation before the call could run',
                    'OpenBox ended this conversation, so ' + call.subject() + ' was not ' + call.verb() + '.'
                );
                call.audit(OpenBoxAudit.STAGE_APPROVAL, 'Halted', null, null);
                continue;
            }
            if (record.Status__c == OpenBoxRequestStatus.PENDING) {
                poll(call);
            }
            if (record.Status__c != OpenBoxRequestStatus.APPROVED) {
                continue;
            }
            if (call.isWrite() || (!toolChosen && canRunHere(record, runAsAgent))) {
                call.runNow = true;
                toolChosen |= !call.isWrite();
            } else {
                call.result.message = canRunHere(record, runAsAgent)
                    ? 'Approved; the ' + record.Tool_Name__c + ' tool will run on the next check.'
                    : 'A human approved the ' + record.Tool_Name__c + ' tool (request ' + record.Name +
                      '). Ask the agent to check on this request to run it.';
            }
        }
        run(calls);
        commitCalls(calls);

        List<Result> outcomes = results(calls);
        Set<Id> settled = requestIds.clone();
        settled.removeAll(locked);
        outcomes.addAll(currentResults(settled));
        return outcomes;
    }

    private Call resumeCall(OpenBox_Governed_Request__c record) {
        Call call = new Call(record);
        call.resumed = true;
        call.input = String.isBlank(record.Tool_Input__c)
            ? new Map<String, Object>()
            : (Map<String, Object>) JSON.deserializeUntyped(record.Tool_Input__c);
        call.standalone = record.Agent_Session__c == null;
        call.result.sessionKey = record.Agent_Session__r?.Session_Key__c ?? record.Agent_Session_Id__c;
        OpenBoxEvents.Identity identity = new OpenBoxEvents.Identity(
            record.Workflow_Id__c,
            record.Run_Id__c,
            settings.workflowType,
            settings.taskQueue,
            settings.agentName,
            call.result.sessionKey
        );
        // A call that is a step of a conversation must not end the conversation's workflow.
        call.run = call.standalone
            ? OpenBoxGovernedRun.resume(client, identity, record.Trace_Id__c, record.CreatedDate)
            : OpenBoxGovernedRun.attach(client, identity, record.Trace_Id__c, record.CreatedDate);
        call.activity = call.run.resumeActivity(record.Activity_Id__c, record.Tool_Name__c, record.CreatedDate);
        if (record.Target_Type__c == TARGET_RECORD_WRITER) {
            call.writer = newWriter(record.Target_Name__c);
            call.changes = call.writer.changes(call.input);
            call.result.changes = call.changes;
        }
        return call;
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
            call.result.message = pendingMessage(call, record.Name);
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
                call.result.message = pendingMessage(call, record.Name);
            }
            when APPROVED {
                record.Decided_At__c = Datetime.now();
                record.Status__c = OpenBoxRequestStatus.APPROVED;
                call.result.status = OpenBoxRequestStatus.APPROVED;
                call.audit(OpenBoxAudit.STAGE_APPROVAL, 'Approved', null, detail);
            }
            when REJECTED, EXPIRED {
                Boolean rejected = approval.status == OpenBoxApprovalResult.State.REJECTED;
                String reason = String.isBlank(approval.reason)
                    ? (rejected ? 'Approval rejected' : 'Approval expired')
                    : approval.reason;
                String errorType = rejected ? 'ApprovalRejected' : 'ApprovalExpired';
                record.Decided_At__c = Datetime.now();
                call.run.failActivity(call.activity, errorType, reason, null);
                finishStandalone(call, false, null, errorType, reason);
                call.conclude(
                    rejected ? OpenBoxRequestStatus.REJECTED : OpenBoxRequestStatus.EXPIRED,
                    reason,
                    capitalize(call.subject()) + ' was ' + (rejected ? 'rejected' : 'not approved in time') + ': ' + reason +
                    '. ' + call.nothingDone()
                );
                call.audit(OpenBoxAudit.STAGE_APPROVAL, rejected ? 'Rejected' : 'Expired', null, detail);
            }
        }
    }

    private static Boolean canRunHere(OpenBox_Governed_Request__c record, Boolean runAsAgent) {
        if (record.Target_Type__c == TARGET_APEX_EXECUTOR || record.Target_Type__c == TARGET_RECORD_WRITER) {
            return true;
        }
        // Flows and actions run as the user who asked, never as the background job's user.
        return runAsAgent == true && record.Requested_By__c == UserInfo.getUserId();
    }

    // ── Execution ───────────────────────────────────────────────────────────────────────────

    /**
     * Runs the authorized calls in the order Apex allows: read-only tools while callouts are
     * still possible, then record writes are prepared (their re-reads and spans are callouts),
     * and only then does anything write.
     */
    private void run(List<Call> calls) {
        for (Call call : calls) {
            if (call.runNow && call.readOnly && !call.resumed) {
                execute(call);
            }
        }
        for (Call call : calls) {
            if (call.runNow && call.isWrite()) {
                try {
                    prepareWrite(call);
                } catch (OpenBoxException e) {
                    failClosed(call, e);
                }
            }
        }
        // From here on the transaction writes: every later event leaves through the outbox.
        for (Call call : calls) {
            if (call.run != null) {
                call.run.deferRemainingEvents();
            }
        }
        for (Call call : calls) {
            if (call.runNow && !call.isWrite() && !(call.readOnly && !call.resumed)) {
                execute(call);
            }
        }
    }

    /**
     * Runs an authorized tool. A read-only tool's completion is decided before its result is
     * returned (output guardrails); anything else is deferred to the outbox, because the tool may
     * have written data and no callout can follow.
     */
    private void execute(Call call) {
        call.runNow = false;
        OpenBox_Governed_Request__c record = call.record;
        Boolean readOnly = call.readOnly && !call.resumed;
        OpenBoxToolContext context = new OpenBoxToolContext(
            record.Requested_By__c,
            call.result.sessionKey,
            record.Request_Id__c,
            call.resumed
        );
        Savepoint savepoint = readOnly ? null : Database.setSavepoint();
        Map<String, Object> output;
        try {
            output = invoke(call, record, call.input, context);
        } catch (Exception e) {
            if (savepoint != null) {
                Database.rollback(savepoint);
            }
            String error = e.getTypeName() + ': ' + e.getMessage();
            call.run.failActivity(call.activity, 'ToolFailed', error, null);
            record.Error__c = error.abbreviate(4000);
            call.conclude(
                OpenBoxRequestStatus.FAILED,
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
                OpenBoxRequestStatus.BLOCKED,
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
            OpenBoxRequestStatus.EXECUTED,
            null,
            'The ' + record.Tool_Name__c + ' tool ran' + (call.resumed ? ' after approval.' : '.')
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
                Object instance = instantiate(record.Target_Name__c);
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

    // ── Record writes: prepare and apply ────────────────────────────────────────────────────

    /**
     * Prepares an authorized write: locked re-read, staleness check, business rule and Salesforce
     * access, then the UPDATE preflight span. The write itself happens in the commit phase.
     */
    private void prepareWrite(Call call) {
        call.runNow = false;
        OpenBoxRecordWriter writer = call.writer;
        OpenBox_Governed_Request__c record = call.record;
        Id recordId = record.Record_Id__c;
        String label = writer.objectType().getDescribe().getLabel();

        String query = selectStatement(call) + ' LIMIT 1 FOR UPDATE';
        OpenBoxSpan reread = OpenBoxSpan.soqlSelect(
            call.run.traceId,
            null,
            objectName(writer),
            literalStatement(selectStatement(call), recordId) + ' FOR UPDATE',
            recordAttributes(writer, recordId)
        );
        if (!spanAllows(call, call.run.spanStarted(call.activity, reread))) {
            return;
        }
        List<SObject> rows = Database.queryWithBinds(
            query,
            new Map<String, Object>{ 'recordId' => recordId },
            AccessLevel.SYSTEM_MODE
        );
        reread.succeeded(rows.size());
        call.run.spanCompleted(call.activity, reread);

        if (rows.isEmpty()) {
            refuseExecution(call, OpenBoxRequestStatus.FAILED, 'RecordNotFound', 'The ' + label + ' no longer exists', 'Write_Failed');
            return;
        }
        SObject fresh = rows[0];
        call.current = fresh;
        if (isStale(record, fresh, call.changes.keySet())) {
            refuseExecution(
                call,
                OpenBoxRequestStatus.STALE,
                'StaleRecord',
                'The ' + label + ' changed after the request was authorized; submit a new request',
                'Stale'
            );
            return;
        }
        String refusal = writer.refusal(fresh, call.input);
        if (refusal != null) {
            refuseExecution(call, OpenBoxRequestStatus.FAILED, 'BusinessRuleViolation', refusal, 'Write_Failed');
            return;
        }
        OpenBoxAccess.Decision access = OpenBoxAccess.canWrite(
            record.Requested_By__c,
            writer.requiredPermission(),
            writer.objectType(),
            call.changes.keySet(),
            recordId
        );
        if (!access.allowed) {
            refuseExecution(call, OpenBoxRequestStatus.PERMISSION_DENIED, 'PermissionDenied', access.reason, 'Permission_Denied');
            return;
        }

        Map<String, Object> attributes = recordAttributes(writer, recordId);
        attributes.put('salesforce.field', String.join(new List<String>(call.changes.keySet()), ','));
        attributes.putAll(writer.writeAttributes(fresh, call.changes));
        OpenBoxSpan writeSpan = OpenBoxSpan.dmlUpdate(
            call.run.traceId,
            null,
            objectName(writer),
            updateStatement(writer, call.changes, recordId),
            attributes
        );
        if (!spanAllows(call, call.run.spanStarted(call.activity, writeSpan))) {
            return;
        }
        SObject change = writer.objectType().newSObject(recordId);
        for (String field : call.changes.keySet()) {
            change.put(field, call.changes.get(field));
        }
        call.updateSpan = writeSpan;
        call.pendingWrite = change;
    }

    /** Applies a span verdict before an operation. Returns true only when it may go ahead. */
    private Boolean spanAllows(Call call, OpenBoxEvaluationResult result) {
        if (result.isAllowed()) {
            return true;
        }
        recordDecision(call, result);
        if (result.verdict == OpenBoxVerdict.REQUIRE_APPROVAL) {
            pend(call, result);
        } else {
            stop(call, call.activity, result, OpenBoxAudit.STAGE_EXECUTION);
        }
        return false;
    }

    private static Boolean isStale(OpenBox_Governed_Request__c record, SObject fresh, Set<String> fields) {
        // SystemModstamp has one-second resolution, so the values the request was authorized
        // against are compared too.
        if (record.Baseline_Modstamp__c != null && (Datetime) fresh.get('SystemModstamp') != record.Baseline_Modstamp__c) {
            return true;
        }
        Map<String, Object> baseline = String.isBlank(record.Baseline_Values__c)
            ? new Map<String, Object>()
            : (Map<String, Object>) JSON.deserializeUntyped(record.Baseline_Values__c);
        for (String field : fields) {
            if (!sameValue(fresh.get(field), baseline.get(field))) {
                return true;
            }
        }
        return false;
    }

    /**
     * Performs every prepared record write in one DML call. Each record is authorized only for the
     * duration of the call, and partial success is allowed so one failure cannot hide another.
     */
    private static void applyWrites(List<Call> calls) {
        List<Call> writers = new List<Call>();
        List<SObject> updates = new List<SObject>();
        Set<Id> written = new Set<Id>();
        for (Call call : calls) {
            if (call.pendingWrite == null) {
                continue;
            }
            if (!written.add(call.pendingWrite.Id)) {
                // Two governed changes to one record in a transaction: the first wins, later ones
                // were authorized against a value that is about to change and are refused.
                recordWriteFailure(call, 'ConcurrentRequest', 'Another governed change to this record was applied in the same transaction');
                continue;
            }
            writers.add(call);
            updates.add(call.pendingWrite);
        }
        if (updates.isEmpty()) {
            return;
        }

        List<Database.SaveResult> saved;
        for (Call call : writers) {
            OpenBoxGovernedWriteContext.authorize(call.pendingWrite.Id, call.changes.keySet());
        }
        try {
            // System mode on purpose: agent users hold guarded fields read-only. Access was verified
            // for the requesting user by OpenBoxAccess immediately before this call.
            saved = Database.update(updates, false, AccessLevel.SYSTEM_MODE);
        } finally {
            OpenBoxGovernedWriteContext.revokeAll();
        }

        for (Integer i = 0; i < writers.size(); i++) {
            Call call = writers[i];
            if (!saved[i].isSuccess()) {
                recordWriteFailure(call, 'DmlException', describeErrors(saved[i].getErrors()));
                continue;
            }
            Map<String, Object> output = call.writer.output(call.current, call.changes);
            call.updateSpan.succeeded(1);
            call.run.spanCompleted(call.activity, call.updateSpan);
            call.run.completeActivity(call.activity, output);
            finishStandalone(call, true, output, null, null);
            call.record.Tool_Output__c = JSON.serialize(output).abbreviate(MAX_LOG_CHARS);
            call.record.Executed_At__c = Datetime.now();
            call.result.executed = true;
            call.result.output = output;
            call.conclude(OpenBoxRequestStatus.EXECUTED, null, call.writer.successMessage(call.current, call.changes));
            call.audit(OpenBoxAudit.STAGE_EXECUTION, 'Executed', null, output);
        }
    }

    private static void recordWriteFailure(Call call, String errorType, String error) {
        call.updateSpan.failed(errorType, error);
        call.run.spanCompleted(call.activity, call.updateSpan);
        call.run.failActivity(call.activity, 'WriteFailed', error, null);
        finishStandalone(call, false, null, 'WriteFailed', error);
        call.record.Error__c = error.abbreviate(4000);
        call.conclude(OpenBoxRequestStatus.FAILED, error, 'OpenBox allowed the change but Salesforce did not apply it: ' + error);
        call.audit(OpenBoxAudit.STAGE_EXECUTION, 'Write_Failed', null, new Map<String, Object>{ 'error' => error });
    }

    // ── Refusals ────────────────────────────────────────────────────────────────────────────

    private void pend(Call call, OpenBoxEvaluationResult decision) {
        recordDecision(call, decision);
        call.record.Approval_Expires_At__c = decision.approvalExpiresAt;
        call.result.approvalExpiresAt = decision.approvalExpiresAt;
        call.record.Status__c = OpenBoxRequestStatus.PENDING;
        call.result.status = OpenBoxRequestStatus.PENDING;
        call.result.message = pendingMessage(call, call.record.Name);
        call.audit(OpenBoxAudit.STAGE_AUTHORIZATION, 'Approval_Required', decision, null);
    }

    /**
     * Ends the call after a refusal (BLOCK or HALT; REQUIRE_APPROVAL on a read is refused too,
     * because a read cannot wait for a human inside an agent turn). activity is the refused
     * activity, or null when it is already closed.
     */
    private void stop(Call call, OpenBoxGovernedRun.Activity activity, OpenBoxEvaluationResult result, String stage) {
        if (result.verdict == OpenBoxVerdict.HALT) {
            halt(call, result, result.reason);
            return;
        }
        block(call, activity, result, stage);
    }

    private void block(Call call, OpenBoxGovernedRun.Activity activity, OpenBoxEvaluationResult decision, String stage) {
        recordDecision(call, decision);
        String reason = reasonOf(decision);
        if (activity != null) {
            call.run.failActivity(activity, 'GovernanceBlocked', reason, null);
        }
        finishStandalone(call, false, null, 'GovernanceBlocked', reason);
        call.conclude(
            OpenBoxRequestStatus.BLOCKED,
            reason,
            'OpenBox blocked ' + (call.isWrite() ? 'this ' + call.writer.changeLabel() : call.subject()) + ': ' + reason + '. ' +
            call.nothingDone()
        );
        call.audit(stage, 'Blocked', decision, null);
    }

    private void halt(Call call, OpenBoxEvaluationResult decision, String reason) {
        if (decision != null) {
            recordDecision(call, decision);
        }
        String why = String.isBlank(reason) ? 'Halted by OpenBox' : reason;
        call.session?.markHalted();
        call.run.finish(false, null, 'halt', why);
        call.conclude(
            OpenBoxRequestStatus.HALTED,
            why,
            'OpenBox ended this conversation: ' + why + '. ' + call.nothingDone()
        );
        call.audit(OpenBoxAudit.STAGE_AUTHORIZATION, 'Halted', decision, null);
    }

    private static void refuseExecution(Call call, String status, String errorType, String reason, String auditOutcome) {
        call.run.failActivity(call.activity, errorType, reason, null);
        finishStandalone(call, false, null, errorType, reason);
        call.conclude(status, reason, 'Nothing was changed: ' + reason + '.');
        call.audit(OpenBoxAudit.STAGE_EXECUTION, auditOutcome, null, null);
    }

    private void failClosed(Call call, OpenBoxException failure) {
        String reason = 'OpenBox governance unavailable: ' + failure.getMessage();
        if (call.run != null && call.activity != null && !call.activity.isClosed()) {
            call.run.failActivity(call.activity, failure.getTypeName(), failure.getMessage(), null);
        }
        finishStandalone(call, false, null, failure.getTypeName(), failure.getMessage());
        call.record.Error__c = reason.abbreviate(4000);
        call.record.Decision__c = call.record.Decision__c == null ? OpenBoxTurnGovernance.VERDICT_ERROR : call.record.Decision__c;
        call.result.verdict = call.record.Decision__c;
        call.conclude(
            OpenBoxRequestStatus.FAILED,
            reason,
            capitalize(call.subject()) + ' was not ' + call.verb() + ' because OpenBox could not authorize it. Try again later.'
        );
        call.audit(OpenBoxAudit.STAGE_AUTHORIZATION, 'Governance_Unavailable', null, new Map<String, Object>{ 'error' => failure.getMessage() });
    }

    private static void rejectInvalid(Call call, String reason) {
        call.record.Decision__c = null;
        call.conclude(OpenBoxRequestStatus.FAILED, reason, 'The request is invalid: ' + reason + '.');
        call.audit(OpenBoxAudit.STAGE_AUTHORIZATION, 'Invalid_Request', null, null);
    }

    /** Ends a call's own run; a conversation's run is closed by the turn instead. */
    private static void finishStandalone(Call call, Boolean succeeded, Object output, String errorType, String error) {
        if (call.standalone && call.run != null && !call.run.isFinished()) {
            call.run.finish(succeeded, output, errorType, error);
        }
    }

    private static void recordDecision(Call call, OpenBoxEvaluationResult decision) {
        call.record.Decision__c = decision.verdict.name();
        call.record.Decision_Id__c = decision.governanceEventId;
        call.record.Policy_Id__c = decision.policyId;
        call.record.Reason__c = decision.reason == null ? null : decision.reason.abbreviate(4000);
        call.result.verdict = call.record.Decision__c;
        call.result.decisionId = decision.governanceEventId;
        call.result.reason = call.record.Reason__c;

        // What Salesforce keeps is what OpenBox input guardrails left of the request.
        Object justification = decision.redactedInputField('justification');
        if (justification != null) {
            call.record.Justification__c = String.valueOf(justification).abbreviate(4000);
        }
        Boolean redacted = false;
        for (String field : call.input.keySet()) {
            Object value = decision.redactedInputField(field);
            if (value != null && value != call.input.get(field)) {
                call.input.put(field, value);
                redacted = true;
            }
        }
        if (redacted) {
            call.record.Tool_Input__c = JSON.serialize(call.input).abbreviate(MAX_LOG_CHARS);
        }
    }

    // ── Commit phase ────────────────────────────────────────────────────────────────────────

    private void commitCalls(List<Call> calls) {
        if (calls.isEmpty()) {
            return;
        }
        List<OpenBox_Governed_Request__c> records = new List<OpenBox_Governed_Request__c>();
        Set<String> saved = new Set<String>();
        for (Call call : calls) {
            if (call.run != null) {
                call.run.deferRemainingEvents();
            }
            if (call.session != null) {
                if (call.run != null && call.run.isHalted()) {
                    call.session.markHalted();
                }
                if (saved.add(call.session.key())) {
                    call.session.save();
                }
                call.record.Agent_Session__c = call.session.record.Id;
            }
            records.add(call.record);
        }
        upsert records;

        applyWrites(calls);
        closeFinishedTurns(calls);
        haltResumedConversations(calls);

        List<OpenBox_Event_Outbox__c> outbox = new List<OpenBox_Event_Outbox__c>();
        List<OpenBox_Governance_Audit__c> audits = new List<OpenBox_Governance_Audit__c>();
        Map<String, Id> requestIds = new Map<String, Id>();
        Boolean pollerNeeded = false;
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
                        call.record.Record_Id__c,
                        call.record.Requested_By__c,
                        new Map<String, Object>{ 'queued_for_retry' => failure }
                    );
                    entry.Action__c = call.record.Action__c;
                    entry.Agent_Session__c = call.record.Agent_Session__c;
                    audits.add(entry);
                }
            }
            // A resolving poller reschedules itself; only newly waiting work needs one queued.
            pollerNeeded |= !call.resumed && waitsForPoller(call.record);
        }
        update records;
        OpenBoxAudit.link(audits, requestIds);
        insert audits;
        insert outbox;
        if (!outbox.isEmpty()) {
            OpenBoxOutboxDispatcher.ensureScheduled();
        }
        if (pollerNeeded) {
            OpenBoxApprovalPoller.ensureScheduled();
        }

        Map<Id, Call> byId = new Map<Id, Call>();
        for (Call call : calls) {
            byId.put(call.record.Id, call);
        }
        for (OpenBox_Governed_Request__c row : [SELECT Id, Name FROM OpenBox_Governed_Request__c WHERE Id IN :byId.keySet()]) {
            Call call = byId.get(row.Id);
            call.result.requestNumber = row.Name;
            if (call.record.Status__c == OpenBoxRequestStatus.PENDING) {
                call.result.message = pendingMessage(call, row.Name);
            }
        }
    }

    /** Whether the background poller has work for the request. */
    public static Boolean waitsForPoller(OpenBox_Governed_Request__c record) {
        return record.Status__c == OpenBoxRequestStatus.PENDING ||
            (record.Status__c == OpenBoxRequestStatus.APPROVED &&
            (record.Target_Type__c == TARGET_APEX_EXECUTOR || record.Target_Type__c == TARGET_RECORD_WRITER));
    }

    /**
     * A turn that ended while a call was waiting for a human was left open; once its last waiting
     * call is resolved, the turn's run is closed with WorkflowCompleted (queued in the outbox).
     */
    private static void closeFinishedTurns(List<Call> calls) {
        Set<Id> resolved = new Set<Id>();
        for (Call call : calls) {
            if (call.resumed && !OpenBoxRequestStatus.isWaiting(call.record.Status__c)) {
                resolved.add(call.record.Id);
            }
        }
        Set<String> closedRuns = new Set<String>();
        for (Call call : calls) {
            OpenBox_Governed_Request__c record = call.record;
            if (
                !resolved.contains(record.Id) ||
                call.run == null ||
                !call.run.isAttached() ||
                call.run.isHalted() ||
                closedRuns.contains(record.Run_Id__c) ||
                !OpenBoxAgentSession.runIsOver(record.Agent_Session__c, record.Run_Id__c, resolved)
            ) {
                continue;
            }
            Boolean succeeded = record.Status__c == OpenBoxRequestStatus.EXECUTED;
            call.run.endConversation(succeeded, null, succeeded ? null : record.Status__c, succeeded ? null : record.Reason__c);
            closedRuns.add(record.Run_Id__c);
        }
    }

    /** A resumed call that OpenBox halted ends its conversation, as a new call would. */
    private static void haltResumedConversations(List<Call> calls) {
        Set<Id> halted = new Set<Id>();
        for (Call call : calls) {
            if (call.resumed && call.run != null && call.run.isHalted() && call.record.Agent_Session__c != null) {
                halted.add(call.record.Agent_Session__c);
            }
        }
        if (halted.isEmpty()) {
            return;
        }
        List<OpenBox_Agent_Session__c> sessions = [SELECT Id FROM OpenBox_Agent_Session__c WHERE Id IN :halted];
        for (OpenBox_Agent_Session__c session : sessions) {
            session.Status__c = OpenBoxAgentSession.STATUS_HALTED;
            session.Closed_At__c = Datetime.now();
        }
        update sessions;
    }

    // ── Helpers ─────────────────────────────────────────────────────────────────────────────

    private static OpenBoxRecordWriter newWriter(String className) {
        Object instance = instantiate(className);
        if (!(instance instanceof OpenBoxRecordWriter)) {
            throw new OpenBoxContractException(className + ' is not an OpenBoxRecordWriter with a no-argument constructor');
        }
        return (OpenBoxRecordWriter) instance;
    }

    private static Object instantiate(String className) {
        Type target = String.isBlank(className) ? null : Type.forName(className);
        return target == null ? null : target.newInstance();
    }

    private static String objectName(OpenBoxRecordWriter writer) {
        return writer.objectType().getDescribe().getName();
    }

    /** The record query with a :recordId bind, as run. */
    private static String selectStatement(Call call) {
        return 'SELECT ' + String.join(call.writer.readFields(call.changes.keySet()), ', ') + ' FROM ' + objectName(call.writer) +
            ' WHERE Id = :recordId';
    }

    /** The statement as reported in a span, with the record id in place of the bind. */
    private static String literalStatement(String statement, Id recordId) {
        return statement.replace(':recordId', '\'' + recordId + '\'');
    }

    private static String updateStatement(OpenBoxRecordWriter writer, Map<String, Object> changes, Id recordId) {
        List<String> assignments = new List<String>();
        for (String field : changes.keySet()) {
            Object value = changes.get(field);
            String literal = value == null
                ? 'null'
                : (value instanceof String ? '\'' + String.escapeSingleQuotes((String) value) + '\'' : String.valueOf(value));
            assignments.add(field + ' = ' + literal);
        }
        return 'UPDATE ' + objectName(writer) + ' SET ' + String.join(assignments, ', ') + ' WHERE Id = \'' + recordId + '\'';
    }

    private static Map<String, Object> recordAttributes(OpenBoxRecordWriter writer, Id recordId) {
        return new Map<String, Object>{
            'salesforce.object' => objectName(writer),
            'salesforce.record_id' => recordId,
            'salesforce.org_id' => UserInfo.getOrganizationId()
        };
    }

    private static Boolean sameValue(Object left, Object right) {
        if (left == null || right == null) {
            return left == right;
        }
        if (isNumber(left) && isNumber(right)) {
            return Decimal.valueOf(String.valueOf(left)) == Decimal.valueOf(String.valueOf(right));
        }
        // Values read back from JSON are strings, numbers and booleans; compare in that form.
        return JSON.serialize(left) == JSON.serialize(right);
    }

    private static Boolean isNumber(Object value) {
        return value instanceof Decimal || value instanceof Integer || value instanceof Long || value instanceof Double;
    }

    private static String describeErrors(List<Database.Error> errors) {
        List<String> messages = new List<String>();
        for (Database.Error error : errors) {
            messages.add(error.getStatusCode() + ': ' + error.getMessage());
        }
        return String.join(messages, '; ');
    }

    private static String pendingMessage(Call call, String requestNumber) {
        OpenBox_Governed_Request__c record = call.record;
        String reference = String.isBlank(requestNumber) ? record.Request_Id__c : requestNumber;
        String message;
        if (call.isWrite()) {
            message = 'This ' + call.writer.changeLabel() + ' needs human approval in OpenBox (request ' + reference +
                '). Nothing has been changed yet; it will be applied automatically if approved';
        } else {
            String next = record.Target_Type__c == TARGET_APEX_EXECUTOR
                ? 'it will run automatically if approved'
                : 'once approved, ask me to check request ' + reference + ' and I will run it';
            message = 'The ' + record.Tool_Name__c + ' tool needs human approval in OpenBox (request ' + reference +
                '). Nothing has run yet; ' + next;
        }
        if (record.Approval_Expires_At__c != null) {
            message += ' before ' + record.Approval_Expires_At__c.formatGmt('yyyy-MM-dd HH:mm') + ' UTC';
        }
        return message + '.';
    }

    private static String reasonOf(OpenBoxEvaluationResult decision) {
        return String.isBlank(decision.reason) ? 'Refused by OpenBox policy' : decision.reason;
    }

    private static String capitalize(String value) {
        return String.isBlank(value) ? value : value.left(1).toUpperCase() + value.substring(1);
    }

    private static List<Result> results(List<Call> calls) {
        List<Result> results = new List<Result>();
        for (Call call : calls) {
            results.add(call.result);
        }
        return results;
    }

    private static List<Result> currentResults(Set<Id> requestIds) {
        List<Result> results = new List<Result>();
        if (requestIds.isEmpty()) {
            return results;
        }
        for (OpenBox_Governed_Request__c record : [
            SELECT
                Name,
                Request_Id__c,
                Tool_Name__c,
                Status__c,
                Decision__c,
                Decision_Id__c,
                Reason__c,
                Record_Id__c,
                Baseline_Values__c,
                Tool_Output__c,
                Approval_Expires_At__c,
                Agent_Session_Id__c
            FROM OpenBox_Governed_Request__c
            WHERE Id IN :requestIds
        ]) {
            Result result = new Call(record).result;
            result.sessionKey = record.Agent_Session_Id__c;
            result.executed = record.Status__c == OpenBoxRequestStatus.EXECUTED;
            if (String.isNotBlank(record.Tool_Output__c)) {
                Object output = JSON.deserializeUntyped(record.Tool_Output__c);
                result.output = output instanceof Map<String, Object> ? (Map<String, Object>) output : null;
            }
            result.message = 'Request ' + record.Name + ' is ' + record.Status__c.replace('_', ' ').toLowerCase() + '.';
            results.add(result);
        }
        return results;
    }

    public class OpenBoxToolException extends Exception {
    }
}
