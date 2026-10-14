/**
 * Resolves pending OpenBox approvals in the background, in a transaction separate from the agent
 * turn that requested them. No Apex transaction ever waits for a human.
 *
 * While approvals are pending the poller re-enqueues itself every
 * OpenBox_Settings__mdt.Approval_Poll_Interval_Minutes__c minutes, oldest-polled requests first;
 * it stops when none remain. OpenBoxApprovalPollerSchedule restarts it hourly in case the chain was
 * ever interrupted, so an approved request is never stranded.
 *
 * Execution of an approved request goes through OpenBoxDiscountGovernance.resolvePending, which
 * locks the request row and re-checks approval, expiry, record state and permissions first.
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
            WHERE Status__c = :OpenBoxDiscountGovernance.STATUS_PENDING
        ];
        if (pending > 0) {
            enqueue(OpenBoxSettings.get().approvalPollIntervalMinutes);
        }
    }

    public void execute(QueueableContext context) {
        OpenBoxSettings settings = OpenBoxSettings.get();
        Map<Id, OpenBox_Governed_Request__c> due = new Map<Id, OpenBox_Governed_Request__c>(
            [
                SELECT Id
                FROM OpenBox_Governed_Request__c
                WHERE Status__c = :OpenBoxDiscountGovernance.STATUS_PENDING
                ORDER BY Last_Polled_At__c ASC NULLS FIRST, CreatedDate ASC
                LIMIT :settings.maxRequestsPerTransaction
            ]
        );
        if (due.isEmpty()) {
            return;
        }
        new OpenBoxDiscountGovernance().resolvePending(due.keySet());
        // If resolving queued outbox events, the dispatcher holds this job's only child slot and
        // re-arms the poller when it finishes.
        ensureScheduledIfPending();
    }

    private static void enqueue(Integer delayMinutes) {
        OpenBoxAsync.enqueueOnce(new OpenBoxApprovalPoller(), SIGNATURE, delayMinutes);
    }
}
