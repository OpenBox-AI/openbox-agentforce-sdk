/**
 * The Agentforce-facing actions: request lookup by reference, ownership, and the poller schedule.
 */
@IsTest
private class OpenBoxActionsTest {
    private static final String ACME_NAME = 'Acme renewal';

    @TestSetup
    static void setup() {
        OpenBoxTestData.createCast();
    }

    @IsTest
    static void checkApprovalResolvesOwnRequestByNumber() {
        OpenBoxTestData.useDefaultSettings();
        Opportunity acme = OpenBoxTestData.opportunityNamed(ACME_NAME);
        User agent = OpenBoxTestData.agentUser();
        OpenBox_Governed_Request__c pending = insertPending(acme, agent.Id);
        String requestNumber = [SELECT Name FROM OpenBox_Governed_Request__c WHERE Id = :pending.Id].Name;
        OpenBoxCoreMock.install().answerApproval('allow', 'Approved by a manager');
        List<OpenBox_GovernedAction.Result> results;

        System.runAs(agent) {
            Test.startTest();
            results = OpenBox_CheckApproval.check(new List<OpenBox_CheckApproval.Request>{ reference(requestNumber) });
            Test.stopTest();
        }

        Assert.areEqual('Executed', results[0].status, results[0].message);
        Assert.isTrue(results[0].executed);
        Assert.areEqual('Book the kickoff', OpenBoxTestData.opportunityNamed(ACME_NAME).NextStep);
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
        List<OpenBox_GovernedAction.Result> results;

        System.runAs(agent) {
            Test.startTest();
            results = OpenBox_CheckApproval.check(new List<OpenBox_CheckApproval.Request>{ reference(resolved.Request_Id__c) });
            Test.stopTest();
        }

        Assert.areEqual('Rejected', results[0].status);
        Assert.isFalse(results[0].executed);
        Assert.areEqual(0, core.requests.size());
    }

    @IsTest
    static void checkApprovalNeverExposesAnotherUsersRequest() {
        OpenBoxTestData.useDefaultSettings();
        Opportunity acme = OpenBoxTestData.opportunityNamed(ACME_NAME);
        OpenBox_Governed_Request__c foreign = insertPending(acme, OpenBoxTestData.adminUser().Id);
        String requestNumber = [SELECT Name FROM OpenBox_Governed_Request__c WHERE Id = :foreign.Id].Name;
        OpenBoxCoreMock core = OpenBoxCoreMock.install();
        List<OpenBox_GovernedAction.Result> results;

        System.runAs(OpenBoxTestData.agentUser()) {
            Test.startTest();
            results = OpenBox_CheckApproval.check(
                new List<OpenBox_CheckApproval.Request>{ reference(requestNumber), reference('GR-999999') }
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

    private static OpenBox_CheckApproval.Request reference(String value) {
        OpenBox_CheckApproval.Request request = new OpenBox_CheckApproval.Request();
        request.requestReference = value;
        return request;
    }

    /** A governed write waiting for approval, as the authorizing transaction left it. */
    private static OpenBox_Governed_Request__c insertPending(Opportunity opportunity, Id requestedBy) {
        String requestId = UUID.randomUUID().toString();
        OpenBox_Governed_Request__c record = new OpenBox_Governed_Request__c(
            Request_Id__c = requestId,
            Action__c = OpenBoxTestWriter.TOOL_NAME,
            Tool_Name__c = OpenBoxTestWriter.TOOL_NAME,
            Tool_Input__c = JSON.serialize(new Map<String, Object>{ 'record_id' => opportunity.Id, 'next_step' => 'Book the kickoff' }),
            Target_Type__c = OpenBoxToolGovernance.TARGET_RECORD_WRITER,
            Target_Name__c = OpenBoxTestWriter.class.getName(),
            Record_Id__c = opportunity.Id,
            Baseline_Modstamp__c = opportunity.SystemModstamp,
            Baseline_Values__c = JSON.serialize(new Map<String, Object>{ 'NextStep' => opportunity.NextStep }),
            Status__c = OpenBoxRequestStatus.PENDING,
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
