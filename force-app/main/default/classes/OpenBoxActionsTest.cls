/**
 * The Agentforce-facing actions: input/output mapping, request lookup by reference, ownership,
 * and the poller schedule.
 */
@IsTest
private class OpenBoxActionsTest {
    private static final String ACME_NAME = 'Acme renewal';

    @TestSetup
    static void setup() {
        OpenBoxTestData.createCast();
    }

    @IsTest
    static void governedUpdateActionMapsAgentInputsAndResult() {
        OpenBoxTestData.useDefaultSettings();
        OpenBoxCoreMock core = OpenBoxCoreMock.install();
        Opportunity acme = OpenBoxTestData.opportunityNamed(ACME_NAME);
        OpenBox_GovernedDiscountUpdate.Request request = new OpenBox_GovernedDiscountUpdate.Request();
        request.opportunityId = acme.Id;
        request.proposedDiscount = 8;
        request.justification = 'Loyal customer';
        request.userPrompt = 'Please give Acme an 8% discount, they renewed early';
        request.agentSessionId = 'session-42';
        List<OpenBox_GovernedDiscountUpdate.Result> results;

        System.runAs(OpenBoxTestData.agentUser()) {
            Test.startTest();
            results = OpenBox_GovernedDiscountUpdate.updateDiscount(
                new List<OpenBox_GovernedDiscountUpdate.Request>{ request }
            );
            Test.stopTest();
        }

        OpenBox_GovernedDiscountUpdate.Result result = results[0];
        Assert.areEqual('Executed', result.status, result.message);
        Assert.isTrue(result.changed);
        Assert.areEqual('ALLOW', result.decision);
        Assert.isTrue(result.requestNumber.startsWith('GR-'), result.requestNumber);
        Assert.isNotNull(result.decisionId);
        Assert.isTrue(result.message.contains('5%') && result.message.contains('8%'), result.message);
        Assert.isNotNull(result.opportunitySummary);

        Map<String, Object> workflowStarted = core.eventsOfType('WorkflowStarted')[0];
        Assert.areEqual(request.userPrompt, workflowStarted.get('goal'), 'the user request is the session goal');
        Assert.areEqual('session-42', workflowStarted.get('session_id'));
        Map<String, Object> signal = core.eventsOfType('SignalReceived')[0];
        Assert.areEqual(new List<Object>{ request.userPrompt }, signal.get('signal_args'));
    }

    @IsTest
    static void checkApprovalResolvesOwnRequestByNumber() {
        OpenBoxTestData.useDefaultSettings();
        Opportunity acme = OpenBoxTestData.opportunityNamed(ACME_NAME);
        User agent = OpenBoxTestData.agentUser();
        OpenBox_Governed_Request__c pending = insertPending(acme, agent.Id);
        String requestNumber = [SELECT Name FROM OpenBox_Governed_Request__c WHERE Id = :pending.Id].Name;
        OpenBoxCoreMock.install().answerApproval('allow', 'Approved by sales ops');
        List<OpenBox_GovernedDiscountUpdate.Result> results;

        System.runAs(agent) {
            Test.startTest();
            results = OpenBox_CheckDiscountApproval.checkApproval(
                new List<OpenBox_CheckDiscountApproval.Request>{ reference(requestNumber) }
            );
            Test.stopTest();
        }

        Assert.areEqual('Executed', results[0].status, results[0].message);
        Assert.isTrue(OpenBoxTestData.opportunityNamed(ACME_NAME).Discount__c == 25);
    }

    @IsTest
    static void checkApprovalReportsResolvedRequestWithoutCallingOpenBox() {
        OpenBoxTestData.useDefaultSettings();
        Opportunity acme = OpenBoxTestData.opportunityNamed(ACME_NAME);
        User agent = OpenBoxTestData.agentUser();
        OpenBox_Governed_Request__c resolved = insertPending(acme, agent.Id);
        resolved.Status__c = 'Rejected';
        update resolved;
        OpenBoxCoreMock core = OpenBoxCoreMock.install();
        List<OpenBox_GovernedDiscountUpdate.Result> results;

        System.runAs(agent) {
            Test.startTest();
            results = OpenBox_CheckDiscountApproval.checkApproval(
                new List<OpenBox_CheckDiscountApproval.Request>{ reference(resolved.Request_Id__c) }
            );
            Test.stopTest();
        }

        Assert.areEqual('Rejected', results[0].status);
        Assert.isFalse(results[0].changed);
        Assert.areEqual(0, core.requests.size());
    }

    @IsTest
    static void checkApprovalNeverExposesAnotherUsersRequest() {
        OpenBoxTestData.useDefaultSettings();
        Opportunity acme = OpenBoxTestData.opportunityNamed(ACME_NAME);
        OpenBox_Governed_Request__c foreign = insertPending(acme, OpenBoxTestData.adminUser().Id);
        String requestNumber = [SELECT Name FROM OpenBox_Governed_Request__c WHERE Id = :foreign.Id].Name;
        OpenBoxCoreMock core = OpenBoxCoreMock.install();
        List<OpenBox_GovernedDiscountUpdate.Result> results;

        System.runAs(OpenBoxTestData.agentUser()) {
            Test.startTest();
            results = OpenBox_CheckDiscountApproval.checkApproval(
                new List<OpenBox_CheckDiscountApproval.Request>{ reference(requestNumber), reference('GR-999999') }
            );
            Test.stopTest();
        }

        Assert.areEqual('Not_Found', results[0].status);
        Assert.areEqual('Not_Found', results[1].status);
        Assert.areEqual(0, core.requests.size());
    }

    @IsTest
    static void pollerScheduleIsInstalledOnce() {
        Test.startTest();
        Id first = OpenBoxApprovalPollerSchedule.install();
        Id second = OpenBoxApprovalPollerSchedule.install();
        Test.stopTest();
        Assert.areEqual(first, second, 'the hourly safety net is installed once');
        Assert.areEqual(1, [SELECT COUNT() FROM CronTrigger WHERE Id = :first]);
    }

    @IsTest
    static void scheduledPollerQueuesResolver() {
        Test.startTest();
        new OpenBoxApprovalPollerSchedule().execute((SchedulableContext) null);
        // The approval poller and the idle-conversation closer.
        Assert.areEqual(2, Limits.getQueueableJobs());
        Test.stopTest();
    }

    @IsTest
    static void pollerWithNothingPendingDoesNothing() {
        OpenBoxTestData.useDefaultSettings();
        OpenBoxCoreMock core = OpenBoxCoreMock.install();
        Test.startTest();
        System.enqueueJob(new OpenBoxApprovalPoller());
        Test.stopTest();
        Assert.areEqual(0, core.requests.size());
    }

    private static OpenBox_CheckDiscountApproval.Request reference(String value) {
        OpenBox_CheckDiscountApproval.Request request = new OpenBox_CheckDiscountApproval.Request();
        request.requestReference = value;
        return request;
    }

    private static OpenBox_Governed_Request__c insertPending(Opportunity opportunity, Id requestedBy) {
        String requestId = UUID.randomUUID().toString();
        OpenBox_Governed_Request__c record = new OpenBox_Governed_Request__c(
            Request_Id__c = requestId,
            Opportunity__c = opportunity.Id,
            Action__c = OpenBoxDiscountGovernance.ACTION,
            Requested_Discount__c = 25,
            Previous_Discount__c = opportunity.Discount__c,
            Baseline_Modstamp__c = opportunity.SystemModstamp,
            Status__c = OpenBoxDiscountGovernance.STATUS_PENDING,
            Decision__c = 'REQUIRE_APPROVAL',
            Workflow_Id__c = 'salesforce-' + UserInfo.getOrganizationId() + '-' + requestId,
            Run_Id__c = requestId,
            Activity_Id__c = UUID.randomUUID().toString(),
            Trace_Id__c = OpenBoxIds.newTraceId(),
            Requested_By__c = requestedBy,
            OwnerId = requestedBy,
            Next_Event_Sequence__c = 0,
            Poll_Count__c = 0
        );
        insert record;
        return record;
    }
}
