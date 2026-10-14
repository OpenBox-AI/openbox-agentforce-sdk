/**
 * Governs agent-initiated Opportunity discount changes with OpenBox.
 *
 * Every request becomes one OpenBox run:
 *
 *   WorkflowStarted                                     goal = what the user asked the agent
 *   SignalReceived  user_prompt                         when the agent passes the utterance
 *   ActivityStarted   OpportunityLookup                 read the record the agent wants to change
 *     span SELECT Opportunity        started -> completed
 *   ActivityCompleted OpportunityLookup                 output guardrails may redact the snapshot
 *   ActivityStarted   OpportunityDiscountUpdate         OpenBox policy + input guardrails decide
 *     span SELECT Opportunity (FOR UPDATE)  started -> completed     locked re-read
 *     span UPDATE Opportunity        started  (behaviour rules decide) -> write -> completed
 *   ActivityCompleted OpportunityDiscountUpdate
 *   WorkflowCompleted | WorkflowFailed
 *
 * Verdicts are enforced before any data changes:
 *   ALLOW            re-read under lock, re-check Salesforce access and business rules, write
 *   BLOCK            no write; the refusal and reason go back to the agent
 *   HALT             no write; OpenBox has ended the session
 *   REQUIRE_APPROVAL no write; the request waits as Pending_Approval and is resumed in a later
 *                    transaction once a human decides in OpenBox (see OpenBoxApprovalPoller)
 * Anything else (OpenBox unreachable, timed out, malformed answer) is a failure, never an approval.
 *
 * Apex forbids callouts after DML in a transaction, so processing is split into a decide phase
 * (callouts and queries only) and a single commit phase (all DML). Events that describe the write
 * itself are produced in the commit phase and leave through the transactional outbox.
 *
 * Replay safety: a pending request executes only from status Pending_Approval, under a row lock,
 * and leaves that status in the same transaction, so a replayed or concurrent resume finds nothing
 * to do. At most one mutation is ever committed per request.
 *
 * Sharing: runs without sharing because approved requests are resumed by a background job whose
 * user need not own the request rows. Data access on behalf of the agent is still enforced: the
 * agent's read runs WITH USER_MODE, and write access is verified for the requesting user by
 * OpenBoxAccess immediately before the write.
 */
public without sharing class OpenBoxDiscountGovernance {
    public static final String ACTION = 'opportunity.update_discount';
    public static final String ACTIVITY_LOOKUP = 'OpportunityLookup';
    public static final String ACTIVITY_UPDATE = 'OpportunityDiscountUpdate';

    public static final String STATUS_AUTHORIZING = 'Authorizing';
    public static final String STATUS_PENDING = 'Pending_Approval';
    public static final String STATUS_EXECUTED = 'Executed';
    public static final String STATUS_BLOCKED = 'Blocked';
    public static final String STATUS_HALTED = 'Halted';
    public static final String STATUS_REJECTED = 'Rejected';
    public static final String STATUS_EXPIRED = 'Expired';
    public static final String STATUS_STALE = 'Stale';
    public static final String STATUS_PERMISSION_DENIED = 'Permission_Denied';
    public static final String STATUS_FAILED = 'Failed';

    @TestVisible
    private static final Integer CALLOUTS_PER_REQUEST = 12;
    // Upper bound of Apex CPU one governed request consumes.
    @TestVisible
    private static final Integer CPU_MS_PER_REQUEST = 3000;
    private static final Decimal MIN_DISCOUNT = 0;
    private static final Decimal MAX_DISCOUNT = 100;
    private static final Integer MAX_DECIMAL_PLACES = 2;
    private static final Integer MAX_JUSTIFICATION_CHARS = 2000;
    private static final Integer MAX_PROMPT_CHARS = 4000;
    private static final String OBJECT_NAME = 'Opportunity';
    private static final String DISCOUNT_FIELD = 'Discount__c';

    public class DiscountRequest {
        public Id opportunityId;
        public Decimal proposedDiscount;
        public String justification;
        public String userPrompt;
        public String agentSessionId;
    }

    public class Outcome {
        public String requestId;
        public String requestNumber;
        public String status;
        public String decision;
        public String decisionId;
        public String reason;
        public Decimal previousDiscount;
        public Decimal requestedDiscount;
        public Boolean changed = false;
        public Datetime approvalExpiresAt;
        public String opportunitySummary;
        public String message;
    }

    /**
     * Everything decided for one request in the decide phase, applied in the commit phase.
     */
    private class Plan {
        final OpenBox_Governed_Request__c record;
        final Outcome outcome = new Outcome();
        final List<OpenBox_Governance_Audit__c> audits = new List<OpenBox_Governance_Audit__c>();
        final Id actorId;
        OpenBoxGovernedRun run;
        OpenBoxGovernedRun.Activity updateActivity;
        OpenBoxSpan updateSpan;
        Opportunity pendingWrite;
        String opportunityName;
        Boolean resumed = false;

        Plan(OpenBox_Governed_Request__c record, Id actorId) {
            this.record = record;
            this.actorId = actorId;
            this.outcome.requestId = record.Request_Id__c;
            this.outcome.requestNumber = record.Name;
            this.outcome.requestedDiscount = record.Requested_Discount__c;
            this.outcome.previousDiscount = record.Previous_Discount__c;
        }

        void audit(String stage, String outcomeName, OpenBoxEvaluationResult decision, Map<String, Object> detail) {
            audits.add(
                OpenBoxAudit.entry(
                    record.Request_Id__c,
                    stage,
                    outcomeName,
                    decision,
                    record.Opportunity__c,
                    actorId,
                    detail
                )
            );
        }

        void conclude(String status, String reason, String message) {
            record.Status__c = status;
            record.Reason__c = reason == null ? record.Reason__c : reason.abbreviate(4000);
            outcome.status = status;
            outcome.reason = record.Reason__c;
            outcome.message = message;
        }
    }

    private final OpenBoxSettings settings;
    private final OpenBoxClient client;

    public OpenBoxDiscountGovernance() {
        this(OpenBoxSettings.get(), new OpenBoxClient());
    }

    @TestVisible
    private OpenBoxDiscountGovernance(OpenBoxSettings settings, OpenBoxClient client) {
        this.settings = settings;
        this.client = client;
    }

    // ── Public entry points ─────────────────────────────────────────────────────────────────

    /**
     * Governs new discount requests. Results are returned in request order.
     */
    public List<Outcome> requestDiscounts(List<DiscountRequest> requests) {
        List<Plan> plans = new List<Plan>();
        for (Integer i = 0; i < requests.size(); i++) {
            Plan plan = newPlan(requests[i]);
            if (i >= settings.maxRequestsPerTransaction) {
                String reason =
                    'At most ' +
                    settings.maxRequestsPerTransaction +
                    ' discount requests are governed per transaction';
                rejectInvalid(plan, reason);
            } else {
                authorize(plan, requests[i]);
            }
            plans.add(plan);
        }
        commitPlans(plans);
        return outcomesOf(plans);
    }

    /**
     * Resolves pending requests against OpenBox: executes approved ones and closes rejected or
     * expired ones. Requests no longer pending (already resolved by a concurrent or replayed call)
     * are skipped and reported as they now stand.
     */
    public List<Outcome> resolvePending(Set<Id> requestIds) {
        List<Plan> plans = new List<Plan>();
        Set<Id> lockedIds = new Set<Id>();
        for (OpenBox_Governed_Request__c record : [
            SELECT
                Id,
                Name,
                Request_Id__c,
                Opportunity__c,
                Requested_Discount__c,
                Previous_Discount__c,
                Baseline_Modstamp__c,
                Status__c,
                Decision__c,
                Decision_Id__c,
                Reason__c,
                Justification__c,
                Workflow_Id__c,
                Run_Id__c,
                Activity_Id__c,
                Trace_Id__c,
                Agent_Session_Id__c,
                Requested_By__c,
                Approval_Expires_At__c,
                Poll_Count__c,
                Next_Event_Sequence__c,
                CreatedDate
            FROM OpenBox_Governed_Request__c
            WHERE Id IN :requestIds AND Status__c = :STATUS_PENDING
            FOR UPDATE
        ]) {
            if (plans.size() >= settings.maxRequestsPerTransaction) {
                break;
            }
            Plan plan = new Plan(record, record.Requested_By__c);
            plan.resumed = true;
            plan.outcome.status = record.Status__c;
            plan.outcome.decision = record.Decision__c;
            plan.outcome.decisionId = record.Decision_Id__c;
            plan.outcome.reason = record.Reason__c;
            plan.outcome.approvalExpiresAt = record.Approval_Expires_At__c;
            resolve(plan);
            plans.add(plan);
            lockedIds.add(record.Id);
        }
        commitPlans(plans);

        List<Outcome> outcomes = outcomesOf(plans);
        Set<Id> untouched = requestIds.clone();
        untouched.removeAll(lockedIds);
        outcomes.addAll(currentOutcomes(untouched));
        return outcomes;
    }

    // ── Decide phase: new requests ──────────────────────────────────────────────────────────

    private Plan newPlan(DiscountRequest request) {
        OpenBox_Governed_Request__c record = new OpenBox_Governed_Request__c(
            Request_Id__c = OpenBoxIds.newRequestId(),
            Opportunity__c = isOpportunityId(request.opportunityId) ? request.opportunityId : null,
            Action__c = ACTION,
            Requested_Discount__c = request.proposedDiscount,
            Requested_By__c = UserInfo.getUserId(),
            Agent_Session_Id__c = request.agentSessionId == null ? null : request.agentSessionId.abbreviate(255),
            Justification__c = request.justification == null ? null : request.justification.abbreviate(4000),
            Status__c = STATUS_AUTHORIZING,
            Next_Event_Sequence__c = 0,
            Poll_Count__c = 0
        );
        return new Plan(record, UserInfo.getUserId());
    }

    private void authorize(Plan plan, DiscountRequest request) {
        String invalid = validate(request);
        if (invalid != null) {
            rejectInvalid(plan, invalid);
            return;
        }
        OpenBoxAccess.Decision entitlement = OpenBoxAccess.canRequest(plan.actorId);
        if (!entitlement.allowed) {
            plan.conclude(STATUS_PERMISSION_DENIED, entitlement.reason, 'Not permitted: ' + entitlement.reason + '.');
            plan.audit(OpenBoxAudit.STAGE_AUTHORIZATION, 'Permission_Denied', null, null);
            return;
        }
        if (OpenBoxClient.remainingCallouts() < CALLOUTS_PER_REQUEST + OpenBoxWorkloadIdentity.pendingCallouts()) {
            rejectInvalid(plan, 'Not enough callout capacity left in this transaction to govern the request');
            return;
        }
        if (Limits.getLimitCpuTime() - Limits.getCpuTime() < CPU_MS_PER_REQUEST) {
            rejectInvalid(plan, 'Not enough processing capacity left in this transaction to govern the request');
            return;
        }

        OpenBoxEvents.Identity identity = new OpenBoxEvents.Identity(
            'salesforce-' + UserInfo.getOrganizationId() + '-' + plan.record.Request_Id__c,
            plan.record.Request_Id__c,
            settings.workflowType,
            settings.taskQueue,
            settings.agentName,
            plan.record.Agent_Session_Id__c
        );
        plan.record.Workflow_Id__c = identity.workflowId;
        plan.record.Run_Id__c = identity.runId;

        try {
            plan.run = OpenBoxGovernedRun.start(client, identity, workflowInput(plan, request), goalOf(request));
            plan.record.Trace_Id__c = plan.run.traceId;
            if (plan.run.isHalted()) {
                stopRun(plan, null, haltResult('Session halted by OpenBox at start'), OpenBoxAudit.STAGE_AUTHORIZATION);
                return;
            }
            plan.run.signalUserPrompt(abbreviate(request.userPrompt, MAX_PROMPT_CHARS));

            Opportunity current = lookup(plan);
            if (current == null) {
                return;
            }
            decideUpdate(plan, current, request);
        } catch (OpenBoxException e) {
            failClosed(plan, e);
        }
    }

    /**
     * The read activity. Its output is what the agent is told about the record, so output-stage
     * guardrails (for example personal-data redaction on the description) apply before it leaves.
     */
    private Opportunity lookup(Plan plan) {
        OpenBoxGovernedRun.Activity activity = plan.run.newActivity(ACTIVITY_LOOKUP);
        OpenBoxEvaluationResult started = plan.run.startActivity(
            activity,
            new Map<String, Object>{
                'request_id' => plan.record.Request_Id__c,
                'salesforce_org_id' => UserInfo.getOrganizationId(),
                'opportunity_id' => plan.record.Opportunity__c,
                'fields' => new List<String>{ 'Name', 'StageName', 'Amount', 'IsClosed', DISCOUNT_FIELD, 'Description' }
            }
        );
        if (!started.isAllowed()) {
            stopActivity(plan, activity, started, OpenBoxAudit.STAGE_AUTHORIZATION);
            return null;
        }

        Id opportunityId = plan.record.Opportunity__c;
        OpenBoxSpan span = OpenBoxSpan.soqlSelect(
            plan.run.traceId,
            null,
            OBJECT_NAME,
            'SELECT Id, Name, StageName, Amount, IsClosed, Discount__c, Description, SystemModstamp FROM Opportunity WHERE Id = \'' +
                opportunityId +
                '\'',
            recordAttributes(opportunityId)
        );
        OpenBoxEvaluationResult preflight = plan.run.spanStarted(activity, span);
        if (!preflight.isAllowed()) {
            stopActivity(plan, activity, preflight, OpenBoxAudit.STAGE_AUTHORIZATION);
            return null;
        }

        List<Opportunity> rows;
        try {
            // The agent reads only what its own user may see.
            rows = [
                SELECT Id, Name, StageName, Amount, IsClosed, Discount__c, Description, SystemModstamp
                FROM Opportunity
                WHERE Id = :opportunityId
                WITH USER_MODE
                LIMIT 1
            ];
        } catch (QueryException e) {
            span.failed('QueryException', e.getMessage());
            plan.run.spanCompleted(activity, span);
            plan.run.failActivity(activity, 'PermissionDenied', e.getMessage(), null);
            plan.run.finish(false, null, 'PermissionDenied', e.getMessage());
            plan.conclude(
                STATUS_PERMISSION_DENIED,
                e.getMessage(),
                'Not permitted: the agent user cannot read this Opportunity.'
            );
            plan.audit(OpenBoxAudit.STAGE_AUTHORIZATION, 'Permission_Denied', null, null);
            return null;
        }
        span.succeeded(rows.size());
        plan.run.spanCompleted(activity, span);

        if (rows.isEmpty()) {
            String reason = 'Opportunity not found or not visible to the requesting user';
            plan.run.failActivity(activity, 'RecordNotFound', reason, null);
            plan.run.finish(false, null, 'RecordNotFound', reason);
            rejectInvalid(plan, reason);
            return null;
        }

        Opportunity current = rows[0];
        plan.opportunityName = current.Name;
        Map<String, Object> snapshot = new Map<String, Object>{
            'opportunity_id' => current.Id,
            'name' => current.Name,
            'stage_name' => current.StageName,
            'amount' => current.Amount,
            'is_closed' => current.IsClosed,
            'current_discount' => current.Discount__c,
            'description' => current.Description
        };
        OpenBoxEvaluationResult completed = plan.run.completeActivity(activity, snapshot);
        if (
            completed != null && (completed.verdict == OpenBoxVerdict.BLOCK || completed.verdict == OpenBoxVerdict.HALT)
        ) {
            stopRun(plan, null, completed, OpenBoxAudit.STAGE_AUTHORIZATION);
            return null;
        }
        Object redactedDescription = completed == null ? null : completed.redactedInputField('description');
        plan.outcome.opportunitySummary = summarize(
            current,
            redactedDescription == null ? current.Description : String.valueOf(redactedDescription)
        );
        return current;
    }

    private void decideUpdate(Plan plan, Opportunity current, DiscountRequest request) {
        plan.record.Previous_Discount__c = current.Discount__c;
        plan.record.Baseline_Modstamp__c = current.SystemModstamp;
        plan.outcome.previousDiscount = current.Discount__c;

        OpenBoxGovernedRun.Activity activity = plan.run.newActivity(ACTIVITY_UPDATE);
        plan.updateActivity = activity;
        plan.record.Activity_Id__c = activity.activityId;

        Decimal previous = current.Discount__c == null ? 0 : current.Discount__c;
        OpenBoxEvaluationResult decision = plan.run.startActivity(
            activity,
            new Map<String, Object>{
                'request_id' => plan.record.Request_Id__c,
                'action' => ACTION,
                'salesforce_org_id' => UserInfo.getOrganizationId(),
                'opportunity_id' => current.Id,
                'opportunity_name' => current.Name,
                'stage_name' => current.StageName,
                'amount' => current.Amount,
                'is_closed' => current.IsClosed,
                'current_discount' => previous,
                'proposed_discount' => request.proposedDiscount,
                'discount_change' => request.proposedDiscount - previous,
                'requested_change' => new Map<String, Object>{ DISCOUNT_FIELD => request.proposedDiscount },
                'justification' => abbreviate(request.justification, MAX_JUSTIFICATION_CHARS),
                'actor_id' => plan.actorId
            }
        );
        recordDecision(plan, decision);

        Object redacted = decision.redactedInputField('justification');
        if (redacted != null) {
            plan.record.Justification__c = String.valueOf(redacted).abbreviate(4000);
        }

        switch on decision.verdict {
            when ALLOW {
                plan.audit(OpenBoxAudit.STAGE_AUTHORIZATION, 'Allowed', decision, null);
                execute(plan, current.SystemModstamp);
            }
            when REQUIRE_APPROVAL {
                pend(plan, decision);
            }
            when else {
                stopActivity(plan, activity, decision, OpenBoxAudit.STAGE_AUTHORIZATION);
            }
        }
    }

    // ── Decide phase: pending requests ──────────────────────────────────────────────────────

    private void resolve(Plan plan) {
        OpenBox_Governed_Request__c record = plan.record;
        record.Last_Polled_At__c = Datetime.now();
        record.Poll_Count__c = (record.Poll_Count__c == null ? 0 : record.Poll_Count__c) + 1;

        OpenBoxEvents.Identity identity = new OpenBoxEvents.Identity(
            record.Workflow_Id__c,
            record.Run_Id__c,
            settings.workflowType,
            settings.taskQueue,
            settings.agentName,
            record.Agent_Session_Id__c
        );
        plan.run = OpenBoxGovernedRun.resume(client, identity, record.Trace_Id__c, record.CreatedDate);
        plan.updateActivity = plan.run.resumeActivity(record.Activity_Id__c, ACTIVITY_UPDATE, record.CreatedDate);

        OpenBoxApprovalResult approval;
        try {
            approval = client.pollApproval(record.Workflow_Id__c, record.Run_Id__c, record.Activity_Id__c);
        } catch (OpenBoxException e) {
            // Still pending: an unreachable OpenBox decides nothing. Retried on the next poll.
            record.Error__c = ('Approval poll failed: ' + e.getMessage()).abbreviate(4000);
            plan.outcome.message = pendingMessage(plan);
            return;
        }
        record.Error__c = null;
        if (approval.expiresAt != null) {
            record.Approval_Expires_At__c = approval.expiresAt;
            plan.outcome.approvalExpiresAt = approval.expiresAt;
        }

        try {
            switch on approval.status {
                when PENDING {
                    plan.outcome.message = pendingMessage(plan);
                }
                when APPROVED {
                    record.Decided_At__c = Datetime.now();
                    plan.audit(OpenBoxAudit.STAGE_APPROVAL, 'Approved', null, approvalDetail(approval));
                    execute(plan, record.Baseline_Modstamp__c);
                }
                when REJECTED, EXPIRED {
                    Boolean rejected = approval.status == OpenBoxApprovalResult.State.REJECTED;
                    String reason = String.isBlank(approval.reason)
                        ? (rejected ? 'Approval rejected' : 'Approval expired')
                        : approval.reason;
                    record.Decided_At__c = Datetime.now();
                    plan.run.failActivity(
                        plan.updateActivity,
                        rejected ? 'ApprovalRejected' : 'ApprovalExpired',
                        reason,
                        null
                    );
                    plan.run.finish(false, null, rejected ? 'ApprovalRejected' : 'ApprovalExpired', reason);
                    plan.conclude(
                        rejected ? STATUS_REJECTED : STATUS_EXPIRED,
                        reason,
                        (rejected
                                ? 'The discount request was rejected: '
                                : 'The discount request expired without approval: ') +
                            reason +
                            '. Nothing was changed.'
                    );
                    plan.audit(
                        OpenBoxAudit.STAGE_APPROVAL,
                        rejected ? 'Rejected' : 'Expired',
                        null,
                        approvalDetail(approval)
                    );
                }
            }
        } catch (OpenBoxException e) {
            failClosed(plan, e);
        }
    }

    // ── Decide phase: shared execution path ─────────────────────────────────────────────────

    /**
     * Prepares the authorized write: locked re-read, staleness check, Salesforce access and
     * business rules, then the UPDATE preflight span. The write itself happens in the commit phase.
     */
    private void execute(Plan plan, Datetime baselineModstamp) {
        OpenBoxGovernedRun.Activity activity = plan.updateActivity;
        Id opportunityId = plan.record.Opportunity__c;

        OpenBoxSpan reread = OpenBoxSpan.soqlSelect(
            plan.run.traceId,
            null,
            OBJECT_NAME,
            'SELECT Id, Name, StageName, IsClosed, Discount__c, SystemModstamp FROM Opportunity WHERE Id = \'' +
                opportunityId +
                '\' FOR UPDATE',
            recordAttributes(opportunityId)
        );
        OpenBoxEvaluationResult preflight = plan.run.spanStarted(activity, reread);
        if (!handleSpanVerdict(plan, preflight)) {
            return;
        }
        List<Opportunity> rows = [
            SELECT Id, Name, StageName, IsClosed, Discount__c, SystemModstamp
            FROM Opportunity
            WHERE Id = :opportunityId
            LIMIT 1
            FOR UPDATE
        ];
        reread.succeeded(rows.size());
        plan.run.spanCompleted(activity, reread);

        if (rows.isEmpty()) {
            refuseExecution(plan, STATUS_FAILED, 'RecordNotFound', 'The Opportunity no longer exists', 'Write_Failed');
            return;
        }
        Opportunity fresh = rows[0];
        plan.opportunityName = fresh.Name;
        // SystemModstamp has one-second resolution, so the authorized discount value is compared too.
        Boolean modified = baselineModstamp != null && fresh.SystemModstamp != baselineModstamp;
        Boolean discountMoved = !sameValue(fresh.Discount__c, plan.record.Previous_Discount__c);
        if (modified || discountMoved) {
            refuseExecution(
                plan,
                STATUS_STALE,
                'StaleRecord',
                'The Opportunity changed after the request was authorized; submit a new request',
                'Stale'
            );
            return;
        }
        if (fresh.IsClosed) {
            refuseExecution(
                plan,
                STATUS_FAILED,
                'BusinessRuleViolation',
                'Closed Opportunities cannot be discounted',
                'Write_Failed'
            );
            return;
        }
        OpenBoxAccess.Decision access = OpenBoxAccess.canUpdateDiscount(plan.actorId, opportunityId);
        if (!access.allowed) {
            refuseExecution(plan, STATUS_PERMISSION_DENIED, 'PermissionDenied', access.reason, 'Permission_Denied');
            return;
        }

        Decimal proposed = plan.record.Requested_Discount__c;
        OpenBoxSpan writeSpan = OpenBoxSpan.dmlUpdate(
            plan.run.traceId,
            null,
            OBJECT_NAME,
            'UPDATE Opportunity SET Discount__c = ' + proposed + ' WHERE Id = \'' + opportunityId + '\'',
            writeAttributes(fresh, proposed)
        );
        OpenBoxEvaluationResult writePreflight = plan.run.spanStarted(activity, writeSpan);
        if (!handleSpanVerdict(plan, writePreflight)) {
            return;
        }

        plan.updateSpan = writeSpan;
        plan.pendingWrite = new Opportunity(Id = opportunityId, Discount__c = proposed);
        plan.run.deferRemainingEvents();
    }

    /**
     * Applies a non-final span verdict. Returns true only when execution may continue.
     */
    private Boolean handleSpanVerdict(Plan plan, OpenBoxEvaluationResult result) {
        if (result.isAllowed()) {
            return true;
        }
        recordDecision(plan, result);
        if (result.verdict == OpenBoxVerdict.REQUIRE_APPROVAL) {
            pend(plan, result);
        } else {
            stopActivity(plan, plan.updateActivity, result, OpenBoxAudit.STAGE_EXECUTION);
        }
        return false;
    }

    private void pend(Plan plan, OpenBoxEvaluationResult decision) {
        recordDecision(plan, decision);
        plan.record.Approval_Expires_At__c = decision.approvalExpiresAt;
        plan.outcome.approvalExpiresAt = decision.approvalExpiresAt;
        plan.record.Status__c = STATUS_PENDING;
        plan.outcome.status = STATUS_PENDING;
        plan.outcome.message = pendingMessage(plan);
        plan.audit(OpenBoxAudit.STAGE_AUTHORIZATION, 'Approval_Required', decision, null);
    }

    private void refuseExecution(Plan plan, String status, String errorType, String reason, String auditOutcome) {
        plan.run.failActivity(plan.updateActivity, errorType, reason, null);
        plan.run.finish(false, null, errorType, reason);
        plan.conclude(status, reason, 'Nothing was changed: ' + reason + '.');
        plan.audit(OpenBoxAudit.STAGE_EXECUTION, auditOutcome, null, null);
    }

    /**
     * Ends the run after a refusal on a specific activity (BLOCK or HALT; REQUIRE_APPROVAL on a
     * read is refused too, because a read cannot wait for a human inside an agent turn).
     */
    private void stopActivity(
        Plan plan,
        OpenBoxGovernedRun.Activity activity,
        OpenBoxEvaluationResult result,
        String stage
    ) {
        if (result.verdict != OpenBoxVerdict.HALT) {
            plan.run.failActivity(activity, 'GovernanceBlocked', result.reason, null);
        }
        stopRun(plan, activity, result, stage);
    }

    private void stopRun(
        Plan plan,
        OpenBoxGovernedRun.Activity activity,
        OpenBoxEvaluationResult result,
        String stage
    ) {
        recordDecision(plan, result);
        Boolean halted = result.verdict == OpenBoxVerdict.HALT;
        String reason = String.isBlank(result.reason) ? 'Refused by OpenBox policy' : result.reason;
        plan.run.finish(false, null, halted ? 'halt' : 'GovernanceBlocked', reason);
        plan.conclude(
            halted ? STATUS_HALTED : STATUS_BLOCKED,
            reason,
            (halted ? 'OpenBox halted this agent session: ' : 'OpenBox blocked this discount change: ') +
                reason +
                '. Nothing was changed.'
        );
        plan.audit(stage, halted ? 'Halted' : 'Blocked', result, null);
    }

    private void failClosed(Plan plan, OpenBoxException failure) {
        String reason = 'OpenBox governance unavailable: ' + failure.getMessage();
        if (plan.run != null && !plan.run.isFinished()) {
            plan.run.finish(false, null, failure.getTypeName(), failure.getMessage());
        }
        plan.record.Error__c = reason.abbreviate(4000);
        plan.record.Decision__c = plan.record.Decision__c == null ? 'ERROR' : plan.record.Decision__c;
        plan.outcome.decision = plan.record.Decision__c;
        plan.conclude(
            STATUS_FAILED,
            reason,
            'The discount was not changed because OpenBox could not authorize it. Try again later.'
        );
        plan.audit(
            OpenBoxAudit.STAGE_AUTHORIZATION,
            'Governance_Unavailable',
            null,
            new Map<String, Object>{ 'error' => failure.getMessage() }
        );
    }

    private void rejectInvalid(Plan plan, String reason) {
        plan.record.Decision__c = null;
        plan.conclude(STATUS_FAILED, reason, 'The request is invalid: ' + reason + '.');
        plan.audit(OpenBoxAudit.STAGE_AUTHORIZATION, 'Invalid_Request', null, null);
    }

    private static void recordDecision(Plan plan, OpenBoxEvaluationResult decision) {
        plan.record.Decision__c = decision.verdict.name();
        plan.record.Decision_Id__c = decision.governanceEventId;
        plan.record.Policy_Id__c = decision.policyId;
        plan.record.Reason__c = decision.reason == null ? null : decision.reason.abbreviate(4000);
        plan.outcome.decision = plan.record.Decision__c;
        plan.outcome.decisionId = decision.governanceEventId;
        plan.outcome.reason = plan.record.Reason__c;
    }

    // ── Commit phase ────────────────────────────────────────────────────────────────────────

    private void commitPlans(List<Plan> plans) {
        if (plans.isEmpty()) {
            return;
        }
        List<OpenBox_Governed_Request__c> records = new List<OpenBox_Governed_Request__c>();
        for (Plan plan : plans) {
            records.add(plan.record);
        }
        upsert records;

        applyWrites(plans);

        List<OpenBox_Governance_Audit__c> audits = new List<OpenBox_Governance_Audit__c>();
        List<OpenBox_Event_Outbox__c> outbox = new List<OpenBox_Event_Outbox__c>();
        Map<String, Id> requestIds = new Map<String, Id>();
        Boolean pendingApprovals = false;
        for (Plan plan : plans) {
            requestIds.put(plan.record.Request_Id__c, plan.record.Id);
            audits.addAll(plan.audits);
            if (plan.run != null) {
                outbox.addAll(OpenBoxOutbox.stage(plan.record, plan.run.drainDeferredEvents()));
                for (String failure : plan.run.telemetryFailures()) {
                    audits.add(
                        OpenBoxAudit.entry(
                            plan.record.Request_Id__c,
                            OpenBoxAudit.STAGE_TELEMETRY,
                            'Governance_Unavailable',
                            null,
                            plan.record.Opportunity__c,
                            plan.actorId,
                            new Map<String, Object>{ 'queued_for_retry' => failure }
                        )
                    );
                }
            }
            // Only a newly pending request starts the poller; a resolving poller reschedules itself.
            pendingApprovals |= !plan.resumed && plan.record.Status__c == STATUS_PENDING;
        }
        update records;
        OpenBoxAudit.link(audits, requestIds);
        insert audits;
        insert outbox;

        if (!outbox.isEmpty()) {
            OpenBoxOutboxDispatcher.ensureScheduled();
        }
        if (pendingApprovals) {
            OpenBoxApprovalPoller.ensureScheduled();
        }
        attachRequestNumbers(plans);
    }

    /**
     * Performs every authorized write in one DML call. Each record is authorized only for the
     * duration of the call, and partial success is allowed so one failure cannot hide another.
     */
    private void applyWrites(List<Plan> plans) {
        List<Plan> writers = new List<Plan>();
        List<Opportunity> updates = new List<Opportunity>();
        Set<Id> authorized = new Set<Id>();
        for (Plan plan : plans) {
            if (plan.pendingWrite == null) {
                continue;
            }
            if (authorized.contains(plan.pendingWrite.Id)) {
                // Two governed changes to one record in a transaction: the first wins, later ones
                // were authorized against a value that is about to change and are refused.
                recordWriteFailure(
                    plan,
                    'ConcurrentRequest',
                    'Another governed discount change to this Opportunity was applied in the same transaction'
                );
                continue;
            }
            writers.add(plan);
            updates.add(plan.pendingWrite);
            authorized.add(plan.pendingWrite.Id);
        }
        if (updates.isEmpty()) {
            return;
        }

        List<Database.SaveResult> results;
        OpenBoxGovernedWriteContext.authorize(authorized);
        try {
            // System mode on purpose: the agent user holds Discount__c read-only. Access was verified
            // for the requesting user by OpenBoxAccess immediately before this call.
            results = Database.update(updates, false, AccessLevel.SYSTEM_MODE);
        } finally {
            OpenBoxGovernedWriteContext.revokeAll();
        }

        for (Integer i = 0; i < writers.size(); i++) {
            Plan plan = writers[i];
            Database.SaveResult result = results[i];
            Decimal proposed = plan.record.Requested_Discount__c;
            if (result.isSuccess()) {
                plan.updateSpan.succeeded(1);
                Map<String, Object> output = new Map<String, Object>{
                    'status' => 'executed',
                    'opportunity_id' => plan.record.Opportunity__c,
                    'previous_discount' => plan.record.Previous_Discount__c,
                    'new_discount' => proposed
                };
                plan.run.spanCompleted(plan.updateActivity, plan.updateSpan);
                plan.run.completeActivity(plan.updateActivity, output);
                plan.run.finish(true, output, null, null);
                plan.record.Executed_At__c = Datetime.now();
                plan.outcome.changed = true;
                plan.conclude(
                    STATUS_EXECUTED,
                    plan.record.Reason__c,
                    'Discount on ' +
                        plan.opportunityName +
                        ' changed from ' +
                        formatPercent(plan.record.Previous_Discount__c) +
                        ' to ' +
                        formatPercent(proposed) +
                        '.'
                );
                plan.audit(OpenBoxAudit.STAGE_EXECUTION, 'Executed', null, output);
            } else {
                recordWriteFailure(plan, 'DmlException', describeErrors(result.getErrors()));
            }
        }
    }

    private static void recordWriteFailure(Plan plan, String errorType, String error) {
        plan.updateSpan.failed(errorType, error);
        plan.run.spanCompleted(plan.updateActivity, plan.updateSpan);
        plan.run.failActivity(plan.updateActivity, 'WriteFailed', error, null);
        plan.run.finish(false, null, 'WriteFailed', error);
        plan.record.Error__c = error.abbreviate(4000);
        plan.conclude(STATUS_FAILED, error, 'OpenBox allowed the change but Salesforce did not apply it: ' + error);
        plan.audit(OpenBoxAudit.STAGE_EXECUTION, 'Write_Failed', null, new Map<String, Object>{ 'error' => error });
    }

    private static void attachRequestNumbers(List<Plan> plans) {
        Map<Id, Plan> byId = new Map<Id, Plan>();
        for (Plan plan : plans) {
            byId.put(plan.record.Id, plan);
        }
        for (OpenBox_Governed_Request__c record : [
            SELECT Id, Name
            FROM OpenBox_Governed_Request__c
            WHERE Id IN :byId.keySet()
        ]) {
            Plan plan = byId.get(record.Id);
            plan.outcome.requestNumber = record.Name;
            if (plan.record.Status__c == STATUS_PENDING) {
                plan.outcome.message = pendingMessage(plan);
            }
        }
    }

    // ── Helpers ─────────────────────────────────────────────────────────────────────────────

    @TestVisible
    private static String validate(DiscountRequest request) {
        if (request == null) {
            return 'The request is empty';
        }
        if (!isOpportunityId(request.opportunityId)) {
            return 'opportunityId must be an Opportunity record id';
        }
        Decimal discount = request.proposedDiscount;
        if (discount == null) {
            return 'proposedDiscount is required';
        }
        if (discount < MIN_DISCOUNT || discount > MAX_DISCOUNT) {
            return 'proposedDiscount must be between ' + MIN_DISCOUNT + ' and ' + MAX_DISCOUNT + ' percent';
        }
        if (discount.setScale(MAX_DECIMAL_PLACES, RoundingMode.DOWN) != discount) {
            return 'proposedDiscount supports at most ' + MAX_DECIMAL_PLACES + ' decimal places';
        }
        return null;
    }

    private static Boolean isOpportunityId(Id value) {
        return value != null && value.getSobjectType() == Opportunity.SObjectType;
    }

    private Map<String, Object> workflowInput(Plan plan, DiscountRequest request) {
        return new Map<String, Object>{
            'request_id' => plan.record.Request_Id__c,
            'action' => ACTION,
            'salesforce_org_id' => UserInfo.getOrganizationId(),
            'opportunity_id' => request.opportunityId,
            'proposed_discount' => request.proposedDiscount,
            'actor_id' => plan.actorId,
            'agent_session_id' => request.agentSessionId
        };
    }

    private static String goalOf(DiscountRequest request) {
        if (String.isNotBlank(request.userPrompt)) {
            return abbreviate(request.userPrompt, MAX_PROMPT_CHARS);
        }
        return 'Set the discount on Opportunity ' +
            request.opportunityId +
            ' to ' +
            request.proposedDiscount +
            ' percent';
    }

    private static Map<String, Object> recordAttributes(Id opportunityId) {
        return new Map<String, Object>{
            'salesforce.object' => OBJECT_NAME,
            'salesforce.record_id' => opportunityId,
            'salesforce.org_id' => UserInfo.getOrganizationId()
        };
    }

    private static Map<String, Object> writeAttributes(Opportunity fresh, Decimal proposed) {
        Map<String, Object> attributes = recordAttributes(fresh.Id);
        attributes.put('salesforce.field', DISCOUNT_FIELD);
        attributes.put('salesforce.opportunity.stage', fresh.StageName);
        attributes.put('salesforce.discount.previous', fresh.Discount__c == null ? 0 : fresh.Discount__c);
        attributes.put('salesforce.discount.proposed', proposed);
        return attributes;
    }

    private static OpenBoxEvaluationResult haltResult(String reason) {
        return new OpenBoxEvaluationResult(new Map<String, Object>{ 'verdict' => 'halt', 'reason' => reason });
    }

    private static Map<String, Object> approvalDetail(OpenBoxApprovalResult approval) {
        return new Map<String, Object>{
            'approval_status' => approval.status.name(),
            'approval_reason' => approval.reason,
            'approval_event_id' => approval.governanceEventId
        };
    }

    private static String pendingMessage(Plan plan) {
        String reference = String.isBlank(plan.outcome.requestNumber) ? plan.record.Request_Id__c : plan.outcome.requestNumber;
        String message =
            'This discount change needs human approval in OpenBox (request ' +
            reference +
            '). Nothing has been changed yet; it will be applied automatically if approved';
        if (plan.record.Approval_Expires_At__c != null) {
            message += ' before ' + plan.record.Approval_Expires_At__c.formatGmt('yyyy-MM-dd HH:mm') + ' UTC';
        }
        return message + '.';
    }

    private static String summarize(Opportunity record, String description) {
        String summary =
            record.Name +
            ' | stage ' +
            record.StageName +
            ' | current discount ' +
            formatPercent(record.Discount__c);
        return String.isBlank(description) ? summary : summary + ' | ' + description.abbreviate(500);
    }

    private static Boolean sameValue(Decimal left, Decimal right) {
        return (left == null ? 0 : left) == (right == null ? 0 : right);
    }

    private static String formatPercent(Decimal value) {
        return (value == null ? '0' : value.stripTrailingZeros().toPlainString()) + '%';
    }

    private static String describeErrors(List<Database.Error> errors) {
        List<String> messages = new List<String>();
        for (Database.Error error : errors) {
            messages.add(error.getStatusCode() + ': ' + error.getMessage());
        }
        return String.join(messages, '; ');
    }

    private static String abbreviate(String value, Integer maxChars) {
        return value == null ? null : value.abbreviate(maxChars);
    }

    private static List<Outcome> outcomesOf(List<Plan> plans) {
        List<Outcome> outcomes = new List<Outcome>();
        for (Plan plan : plans) {
            outcomes.add(plan.outcome);
        }
        return outcomes;
    }

    private static List<Outcome> currentOutcomes(Set<Id> requestIds) {
        List<Outcome> outcomes = new List<Outcome>();
        if (requestIds.isEmpty()) {
            return outcomes;
        }
        for (OpenBox_Governed_Request__c record : [
            SELECT
                Name,
                Request_Id__c,
                Status__c,
                Decision__c,
                Decision_Id__c,
                Reason__c,
                Previous_Discount__c,
                Requested_Discount__c,
                Approval_Expires_At__c,
                Executed_At__c
            FROM OpenBox_Governed_Request__c
            WHERE Id IN :requestIds
        ]) {
            Outcome outcome = new Outcome();
            outcome.requestId = record.Request_Id__c;
            outcome.requestNumber = record.Name;
            outcome.status = record.Status__c;
            outcome.decision = record.Decision__c;
            outcome.decisionId = record.Decision_Id__c;
            outcome.reason = record.Reason__c;
            outcome.previousDiscount = record.Previous_Discount__c;
            outcome.requestedDiscount = record.Requested_Discount__c;
            outcome.approvalExpiresAt = record.Approval_Expires_At__c;
            outcome.changed = record.Status__c == STATUS_EXECUTED;
            outcome.message =
                'Request ' +
                record.Name +
                ' is ' +
                record.Status__c.replace('_', ' ').toLowerCase() +
                '.';
            outcomes.add(outcome);
        }
        return outcomes;
    }
}
