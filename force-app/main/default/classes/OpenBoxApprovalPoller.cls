/**
 * Resolves pending OpenBox approvals in the background, in a transaction separate from the agent
 * turn that requested them. No Apex transaction ever waits for a human.
 *
 * While approvals are pending the poller re-enqueues itself every
 * OpenBox_Settings__mdt.Approval_Poll_Interval_Minutes__c minutes, oldest-polled requests first;
 * it stops when none remain. OpenBoxApprovalPollerSchedule restarts it hourly in case the chain was
 * ever interrupted, so an approved request is never stranded.
 *
 * Execution of an approved request goes through OpenBoxToolGovernance.resolve, which locks the
 * request row and re-checks approval, expiry and the conversation's state first. Approved flows
 * and standard actions are not run here: they must run as the agent's own user, so they wait as
 * Approved until the agent checks on them.
 */
public inherited sharing class OpenBoxApprovalPoller implements Queueable, Database.AllowsCallouts {
    private static final String SIGNATURE = 'OpenBoxApprovalPoller';
    // Approved calls the poller may run itself; flows and actions wait for the agent.
    private static final Set<String> POLLER_TARGETS = new Set<String>{
        OpenBoxToolGovernance.TARGET_APEX_EXECUTOR,
        OpenBoxToolGovernance.TARGET_RECORD_WRITER
    };

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
                Status__c = :OpenBoxRequestStatus.PENDING
                OR (Status__c = :OpenBoxRequestStatus.APPROVED
                AND Target_Type__c IN :POLLER_TARGETS)
        ];
        if (pending > 0) {
            enqueue(OpenBoxSettings.get().approvalPollIntervalMinutes);
        }
    }

    public void execute(QueueableContext context) {
        OpenBoxSettings settings = OpenBoxSettings.get();
        Set<Id> due = new Map<Id, OpenBox_Governed_Request__c>([
            SELECT Id
            FROM OpenBox_Governed_Request__c
            WHERE
                Status__c = :OpenBoxRequestStatus.PENDING
                OR (Status__c = :OpenBoxRequestStatus.APPROVED
                AND Target_Type__c IN :POLLER_TARGETS)
            ORDER BY Last_Polled_At__c ASC NULLS FIRST, CreatedDate ASC
            LIMIT :settings.maxRequestsPerTransaction
        ]).keySet();
        if (due.isEmpty()) {
            return;
        }
        new OpenBoxToolGovernance().resolve(due, false);
        // If resolving queued outbox events, the dispatcher holds this job's only child slot and
        // re-arms the poller when it finishes.
        ensureScheduledIfPending();
    }

    private static void enqueue(Integer delayMinutes) {
        OpenBoxAsync.enqueueOnce(new OpenBoxApprovalPoller(), SIGNATURE, delayMinutes);
    }
}
