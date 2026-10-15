/**
 * Ends idle agent conversations in OpenBox.
 *
 * Agentforce has no "conversation ended" hook, so a conversation that has seen no message or tool
 * call for OpenBox_Settings__mdt.Session_Idle_Minutes__c minutes (default 60) is closed with
 * WorkflowCompleted. A conversation with a call still waiting on approval stays open. If the user
 * comes back later, the next message starts a new OpenBox run for the same conversation.
 *
 * Started by OpenBoxApprovalPollerSchedule every hour.
 */
public inherited sharing class OpenBoxSessionCloser implements Queueable, Database.AllowsCallouts {
    private static final String SIGNATURE = 'OpenBoxSessionCloser';
    private static final Integer DEFAULT_IDLE_MINUTES = 60;
    private static final Integer BATCH_SIZE = 20;
    // A close sends at most a few events; stop well before the callout limit.
    private static final Integer CALLOUTS_PER_SESSION = 4;

    public static void ensureScheduled() {
        OpenBoxAsync.enqueueOnce(new OpenBoxSessionCloser(), SIGNATURE, 0);
    }

    public void execute(QueueableContext context) {
        OpenBoxSettings settings = OpenBoxSettings.get();
        OpenBoxClient client = new OpenBoxClient();
        Datetime cutoff = Datetime.now().addMinutes(-idleMinutes());
        List<OpenBox_Agent_Session__c> idle = [
            SELECT Id, Session_Key__c, Workflow_Id__c, Run_Id__c, Trace_Id__c, Started_At__c, Turn_Count__c, Next_Event_Sequence__c
            FROM OpenBox_Agent_Session__c
            WHERE
                Status__c = :OpenBoxAgentSession.STATUS_ACTIVE
                AND Last_Activity_At__c < :cutoff
                AND Id NOT IN (
                    SELECT Agent_Session__c
                    FROM OpenBox_Governed_Request__c
                    WHERE Status__c IN (:OpenBoxDiscountGovernance.STATUS_PENDING, :OpenBoxToolGovernance.STATUS_APPROVED)
                )
            LIMIT :BATCH_SIZE
            FOR UPDATE
        ];

        List<OpenBox_Agent_Session__c> closed = new List<OpenBox_Agent_Session__c>();
        List<OpenBoxGovernedRun> runs = new List<OpenBoxGovernedRun>();
        for (OpenBox_Agent_Session__c session : idle) {
            if (OpenBoxClient.remainingCallouts() < CALLOUTS_PER_SESSION + OpenBoxWorkloadIdentity.pendingCallouts()) {
                break;
            }
            if (String.isBlank(session.Run_Id__c)) {
                continue;
            }
            OpenBoxGovernedRun run = OpenBoxGovernedRun.attach(
                client,
                new OpenBoxEvents.Identity(
                    session.Workflow_Id__c,
                    session.Run_Id__c,
                    settings.workflowType,
                    settings.taskQueue,
                    settings.agentName,
                    session.Session_Key__c
                ),
                session.Trace_Id__c,
                session.Started_At__c
            );
            // Telemetry never raises; an undelivered close is queued in the outbox.
            run.endConversation(
                true,
                new Map<String, Object>{ 'reason' => 'idle', 'turns' => session.Turn_Count__c },
                null,
                null
            );
            session.Status__c = OpenBoxAgentSession.STATUS_CLOSED;
            session.Closed_At__c = Datetime.now();
            closed.add(session);
            runs.add(run);
        }

        List<OpenBox_Event_Outbox__c> outbox = new List<OpenBox_Event_Outbox__c>();
        for (Integer i = 0; i < closed.size(); i++) {
            outbox.addAll(OpenBoxOutbox.stage(closed[i], runs[i].drainDeferredEvents()));
        }
        update closed;
        insert outbox;
        if (!outbox.isEmpty()) {
            OpenBoxOutboxDispatcher.ensureScheduled();
        }
    }

    private static Integer idleMinutes() {
        OpenBox_Settings__mdt record = OpenBox_Settings__mdt.getInstance('Default');
        Decimal configured = record?.Session_Idle_Minutes__c;
        return configured == null || configured < 5 ? DEFAULT_IDLE_MINUTES : configured.intValue();
    }
}
