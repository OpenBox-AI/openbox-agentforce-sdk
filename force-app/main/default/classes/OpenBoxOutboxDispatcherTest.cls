/**
 * Outbox delivery: order within a request, retries that hold back successors, exhaustion, and
 * Core refusals after a halted session.
 */
@IsTest
private class OpenBoxOutboxDispatcherTest {
    @TestSetup
    static void setup() {
        insert new OpenBox_Governed_Request__c(
            Request_Id__c = UUID.randomUUID().toString(),
            Status__c = 'Executed',
            Next_Event_Sequence__c = 0
        );
    }

    private static OpenBox_Governed_Request__c request() {
        return [SELECT Id, Request_Id__c, Next_Event_Sequence__c FROM OpenBox_Governed_Request__c LIMIT 1];
    }

    private static List<OpenBox_Event_Outbox__c> stageThree(OpenBox_Governed_Request__c request) {
        OpenBoxEvents.Identity identity = new OpenBoxEvents.Identity(
            'wf',
            request.Request_Id__c,
            'AgentforceGovernedAction',
            null,
            null,
            null
        );
        List<Map<String, Object>> events = new List<Map<String, Object>>{
            OpenBoxEvents.activityCompleted(identity, 'a1', 'OpportunityDiscountUpdate', 'completed', null, null, 1),
            OpenBoxEvents.workflowCompleted(identity, 'completed', null, null, 2),
            OpenBoxEvents.signalReceived(identity, 'audit', new List<Object>())
        };
        List<OpenBox_Event_Outbox__c> rows = OpenBoxOutbox.stage(request, events);
        insert rows;
        update request;
        return rows;
    }

    @IsTest
    static void stagingNumbersEventsAndAdvancesCursor() {
        OpenBox_Governed_Request__c request = request();
        List<OpenBox_Event_Outbox__c> rows = stageThree(request);
        Assert.isTrue(rows[0].Sequence__c == 0 && rows[2].Sequence__c == 2);
        Assert.areEqual('ActivityCompleted', rows[0].Event_Type__c);
        Assert.isTrue(request().Next_Event_Sequence__c == 3, 'the cursor continues across transactions');
    }

    @IsTest
    static void deliversInSequenceOrder() {
        OpenBoxTestData.useDefaultSettings();
        stageThree(request());
        OpenBoxCoreMock core = OpenBoxCoreMock.install();

        Test.startTest();
        System.enqueueJob(new OpenBoxOutboxDispatcher());
        Test.stopTest();

        Assert.areEqual(
            new List<String>{
                'ActivityCompleted:OpportunityDiscountUpdate',
                'WorkflowCompleted:AgentforceGovernedAction',
                'SignalReceived:audit'
            },
            core.eventSequence()
        );
        Assert.areEqual(
            3,
            [SELECT COUNT() FROM OpenBox_Event_Outbox__c WHERE Status__c = 'Sent' AND Sent_At__c != NULL]
        );
    }

    @IsTest
    static void failedEventHoldsBackSuccessorsAndIsRetried() {
        OpenBoxTestData.useDefaultSettings();
        stageThree(request());
        OpenBoxCoreMock core = OpenBoxCoreMock.install().failNext(2, 503);

        Test.startTest();
        System.enqueueJob(new OpenBoxOutboxDispatcher());
        Test.stopTest();

        Assert.areEqual(2, core.requests.size(), 'one event, one retry, and nothing sent past it');
        List<OpenBox_Event_Outbox__c> rows = [
            SELECT Status__c, Attempts__c, Last_Error__c
            FROM OpenBox_Event_Outbox__c
            ORDER BY Sequence__c
        ];
        Assert.areEqual('Queued', rows[0].Status__c);
        Assert.isTrue(rows[0].Attempts__c == 1);
        Assert.isTrue(rows[0].Last_Error__c.contains('503'));
        Assert.areEqual('Queued', rows[1].Status__c, 'successors wait for the failed event');
        Assert.isTrue(rows[1].Attempts__c == 0);
    }

    @IsTest
    static void exhaustedEventIsMarkedFailedSoSuccessorsCanClose() {
        OpenBoxTestData.useDefaultSettings();
        List<OpenBox_Event_Outbox__c> rows = stageThree(request());
        rows[0].Attempts__c = 2;
        update rows[0];
        OpenBoxCoreMock.install().failNext(2, 503);

        Test.startTest();
        System.enqueueJob(new OpenBoxOutboxDispatcher());
        Test.stopTest();

        List<OpenBox_Event_Outbox__c> after = [SELECT Status__c FROM OpenBox_Event_Outbox__c ORDER BY Sequence__c];
        Assert.areEqual('Failed', after[0].Status__c);
        Assert.areEqual('Sent', after[1].Status__c);
        Assert.areEqual('Sent', after[2].Status__c);
    }

    @IsTest
    static void eventsForHaltedSessionAreMarkedRejected() {
        OpenBoxTestData.useDefaultSettings();
        stageThree(request());
        OpenBoxCoreMock.install()
            .answerRaw(
                '{"verdict":"halt","action":"halt","reason":"Session is no longer active","governance_event_id":"00000000-0000-0000-0000-000000000000"}'
            );

        Test.startTest();
        System.enqueueJob(new OpenBoxOutboxDispatcher());
        Test.stopTest();

        Assert.areEqual(3, [SELECT COUNT() FROM OpenBox_Event_Outbox__c WHERE Status__c = 'Rejected']);
    }

    @IsTest
    static void outputGuardrailFailureOnCompletionIsAudited() {
        OpenBoxTestData.useDefaultSettings();
        stageThree(request());
        OpenBoxCoreMock.install()
            .answerRaw(
                '{"verdict":"allow","action":"allow","governance_event_id":"e1","guardrails_result":{"validation_passed":false,"reasons":[{"reason":"Output contains banned words"}]}}'
            );

        Test.startTest();
        System.enqueueJob(new OpenBoxOutboxDispatcher());
        Test.stopTest();

        List<OpenBox_Governance_Audit__c> audits = [
            SELECT Outcome__c, Governed_Request__c, Detail__c
            FROM OpenBox_Governance_Audit__c
        ];
        Assert.areEqual(3, audits.size());
        Assert.areEqual('Guardrail_Violation', audits[0].Outcome__c);
        Assert.areEqual(request().Id, audits[0].Governed_Request__c);
        Assert.isTrue(audits[0].Detail__c.contains('Output contains banned words'));
    }

    @IsTest
    static void ensureScheduledIsIdempotent() {
        Test.startTest();
        OpenBoxOutboxDispatcher.ensureScheduled();
        OpenBoxOutboxDispatcher.ensureScheduled();
        Assert.areEqual(1, Limits.getQueueableJobs(), 'a duplicate dispatcher is never queued');
        Test.stopTest();
    }
}
