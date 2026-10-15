/**
 * Resolves pending OpenBox approvals in the background, in a transaction separate from the agent
 * turn that requested them. No Apex transaction ever waits for a human.
 *
 * While approvals are pending the poller re-enqueues itself every
 * OpenBox_Settings__mdt.Approval_Poll_Interval_Minutes__c minutes, oldest-polled requests first;
 * it stops when none remain. OpenBoxApprovalPollerSchedule restarts it hourly in case the chain was
 * ever interrupted, so an approved request is never stranded.
 *
 * Execution of an approved request goes through OpenBoxDiscountGovernance.resolvePending (the
 * discount action) or OpenBoxToolGovernance.resolve (any other governed tool), which lock the
 * request row and re-check approval, expiry and the conversation's state first. Approved flows
 * and standard actions are not run here: they must run as the agent's own user, so they wait as
 * Approved until the agent checks on them.
 */
public inherited sharing class OpenBoxApprovalPoller implements Queueable, Database.AllowsCallouts {
    private static final String SIGNATURE = 'OpenBoxApprovalPoller';

    /**
     * Queues the poller unless one is already queued.
     */
    public static void ensureScheduled() {
        enqueue(0);
    }

    /**
     * Queues the poller after the configured interval when any approval is still pending. Called
     * by jobs that may have taken the single child-job slot the poller needed for itself.
     */
    public static void ensureScheduledIfPending() {
        Integer pending = [
            SELECT COUNT()
            FROM OpenBox_Governed_Request__c
            WHERE
                Status__c = :OpenBoxDiscountGovernance.STATUS_PENDING
                OR (Status__c = :OpenBoxToolGovernance.STATUS_APPROVED
                AND Target_Type__c = :OpenBoxToolGovernance.TARGET_APEX_EXECUTOR)
        ];
        if (pending > 0) {
            enqueue(OpenBoxSettings.get().approvalPollIntervalMinutes);
        }
    }

    public void execute(QueueableContext context) {
        OpenBoxSettings settings = OpenBoxSettings.get();
        List<OpenBox_Governed_Request__c> waiting = [
            SELECT Id, Tool_Name__c
            FROM OpenBox_Governed_Request__c
            WHERE
                Status__c = :OpenBoxDiscountGovernance.STATUS_PENDING
                OR (Status__c = :OpenBoxToolGovernance.STATUS_APPROVED
                AND Target_Type__c = :OpenBoxToolGovernance.TARGET_APEX_EXECUTOR)
            ORDER BY Last_Polled_At__c ASC NULLS FIRST, CreatedDate ASC
            LIMIT 200
        ];
        if (waiting.isEmpty()) {
            return;
        }
        // Discount requests and tool calls each write in their own commit phase, and Apex allows no
        // callout after a write, so one kind is resolved per run: the kind that has waited longest.
        Boolean tools = waiting[0].Tool_Name__c != null;
        Set<Id> due = new Set<Id>();
        for (OpenBox_Governed_Request__c row : waiting) {
            if ((row.Tool_Name__c != null) == tools && due.size() < settings.maxRequestsPerTransaction) {
                due.add(row.Id);
            }
        }
        if (tools) {
            new OpenBoxToolGovernance().resolve(due, false);
        } else {
            new OpenBoxDiscountGovernance().resolvePending(due);
        }
        // If resolving queued outbox events, the dispatcher holds this job's only child slot and
        // re-arms the poller when it finishes.
        ensureScheduledIfPending();
    }

    private static void enqueue(Integer delayMinutes) {
        OpenBoxAsync.enqueueOnce(new OpenBoxApprovalPoller(), SIGNATURE, delayMinutes);
    }
}
