/**
 * The reference agent's actions on top of the OpenBox SDK: the discount action's input and output
 * mapping, checking on a discount approval, the registered note-logging flow, and the actions
 * inside a governed conversation.
 */
@IsTest
private class OpenBoxReferenceAgentTest {
    private static final String ACME_NAME = 'Acme renewal';
    private static final String KEY = 'conversation-test-key';
    private static final String RUN_ID = 'run-conversation-test';

    @TestSetup
    static void setup() {
        OpportunityDiscountTestData.createCast();
    }

    // ── Discount action ─────────────────────────────────────────────────────────────────────

    @IsTest
    static void governedUpdateActionMapsAgentInputsAndResult() {
        OpenBoxTestData.useDefaultSettings();
        OpenBoxCoreMock core = OpenBoxCoreMock.install();
        Opportunity acme = OpportunityDiscountTestData.opportunityNamed(ACME_NAME);
        OpenBox_GovernedDiscountUpdate.Request request = new OpenBox_GovernedDiscountUpdate.Request();
        request.opportunityId = acme.Id;
        request.proposedDiscount = 8;
        request.justification = 'Loyal customer';
        request.userPrompt = 'Please give Acme an 8% discount, they renewed early';
        request.agentSessionId = 'session-42';
        List<OpenBox_GovernedDiscountUpdate.Result> results;

        System.runAs(OpenBoxTestData.agentUser()) {
            Test.startTest();
            results = OpenBox_GovernedDiscountUpdate.updateDiscount(new List<OpenBox_GovernedDiscountUpdate.Request>{ request });
            Test.stopTest();
        }

        OpenBox_GovernedDiscountUpdate.Result result = results[0];
        Assert.areEqual('Executed', result.status, result.message);
        Assert.isTrue(result.changed);
        Assert.areEqual('ALLOW', result.decision);
        Assert.isTrue(result.requestNumber.startsWith('GR-'), result.requestNumber);
        Assert.isNotNull(result.decisionId);
        Assert.isTrue(result.previousDiscount == 5);
        Assert.isTrue(result.requestedDiscount == 8);
        Assert.areEqual('Discount on Acme renewal changed from 5% to 8%.', result.message);
        Assert.isNotNull(result.opportunitySummary);

        Map<String, Object> workflowStarted = core.eventsOfType('WorkflowStarted')[0];
        Assert.areEqual(request.userPrompt, workflowStarted.get('goal'), 'the user request is the session goal');
        Assert.areEqual('session-42', workflowStarted.get('session_id'));
        Map<String, Object> signal = core.eventsOfType('SignalReceived')[0];
        Assert.areEqual(new List<Object>{ request.userPrompt }, signal.get('signal_args'));

        // The facts the provisioned OpenBox policies decide on.
        for (Map<String, Object> event : core.eventsOfType('ActivityStarted')) {
            if (event.get('activity_type') == OpportunityDiscountWriter.TOOL_NAME && event.get('hook_trigger') != true) {
                Map<String, Object> facts = (Map<String, Object>) ((List<Object>) event.get('activity_input'))[0];
                Assert.areEqual(false, facts.get('is_closed'));
                Assert.isTrue(Decimal.valueOf(String.valueOf(facts.get('proposed_discount'))) == 8);
                Assert.isTrue(Decimal.valueOf(String.valueOf(facts.get('current_discount'))) == 5);
                Assert.areEqual('Loyal customer', facts.get('justification'));
                Assert.areEqual('opportunity.update_discount', facts.get('action'));
            }
        }
    }

    @IsTest
    static void checkDiscountApprovalResolvesOwnRequestByNumber() {
        OpenBoxTestData.useDefaultSettings();
        Opportunity acme = OpportunityDiscountTestData.opportunityNamed(ACME_NAME);
        User agent = OpenBoxTestData.agentUser();
        OpenBox_Governed_Request__c pending = OpportunityDiscountTestData.pendingRequest(acme, 25, agent.Id);
        String requestNumber = [SELECT Name FROM OpenBox_Governed_Request__c WHERE Id = :pending.Id].Name;
        OpenBoxCoreMock.install().answerApproval('allow', 'Approved by sales ops');
        List<OpenBox_GovernedDiscountUpdate.Result> results;

        System.runAs(agent) {
            Test.startTest();
            results = OpenBox_CheckDiscountApproval.checkApproval(new List<OpenBox_CheckDiscountApproval.Request>{ reference(requestNumber) });
            Test.stopTest();
        }

        Assert.areEqual('Executed', results[0].status, results[0].message);
        Assert.isTrue(results[0].changed);
        Assert.isTrue(OpportunityDiscountTestData.opportunityNamed(ACME_NAME).Discount__c == 25);
    }

    @IsTest
    static void checkDiscountApprovalReportsResolvedRequestWithoutCallingOpenBox() {
        OpenBoxTestData.useDefaultSettings();
        Opportunity acme = OpportunityDiscountTestData.opportunityNamed(ACME_NAME);
        User agent = OpenBoxTestData.agentUser();
        OpenBox_Governed_Request__c resolved = OpportunityDiscountTestData.pendingRequest(acme, 25, agent.Id);
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
    static void checkDiscountApprovalNeverExposesAnotherUsersRequest() {
        OpenBoxTestData.useDefaultSettings();
        Opportunity acme = OpportunityDiscountTestData.opportunityNamed(ACME_NAME);
        OpenBox_Governed_Request__c foreign = OpportunityDiscountTestData.pendingRequest(acme, 25, OpenBoxTestData.adminUser().Id);
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

    // ── Registered flow ─────────────────────────────────────────────────────────────────────

    @IsTest
    static void registeredFlowRunsThroughTheGovernedAction() {
        OpenBoxTestData.useDefaultSettings();
        OpenBoxCoreMock core = OpenBoxCoreMock.install();
        Opportunity acme = OpportunityDiscountTestData.opportunityNamed(ACME_NAME);
        OpenBox_GovernedAction.Result ran;
        OpenBox_GovernedAction.Result badJson;
        System.runAs(OpenBoxTestData.agentUser()) {
            Test.startTest();
            badJson = OpenBoxConversationTest.runTool('log_opportunity_note', 'not json');
            ran = OpenBoxConversationTest.runTool('log_opportunity_note', OpenBoxConversationTest.noteJson(acme.Id, 'First call'));
            Test.stopTest();
        }
        Assert.areEqual(OpenBoxRequestStatus.EXECUTED, ran.status, OpenBoxConversationTest.why(ran.reason));
        Assert.isTrue(ran.executed);
        Assert.areEqual(1, [SELECT COUNT() FROM Task WHERE WhatId = :acme.Id AND Subject = 'First call']);
        Assert.areEqual('log_opportunity_note', core.eventsOfType('ActivityStarted')[0].get('activity_type'));
        Assert.areEqual('Failed', badJson.status);
    }

    @IsTest
    static void approvedFlowWaitsForTheAgentThenRunsOnce() {
        OpenBoxTestData.useDefaultSettings();
        Opportunity acme = OpportunityDiscountTestData.opportunityNamed(ACME_NAME);
        String requestNumber;
        System.runAs(OpenBoxTestData.agentUser()) {
            Id sessionId = OpenBoxConversationTest.seedSession('Log a note', 'discount_management').Id;
            Id requestId = OpenBoxConversationTest.seedPendingTool(
                'log_opportunity_note',
                OpenBoxToolGovernance.TARGET_FLOW,
                'OpenBox_Log_Opportunity_Note',
                OpenBoxConversationTest.noteJson(acme.Id, 'Second call'),
                sessionId
            );
            requestNumber = [SELECT Name FROM OpenBox_Governed_Request__c WHERE Id = :requestId].Name;
        }
        OpenBoxCoreMock.install().answerApproval('allow', null);

        Test.startTest();
        // The background poller learns of the approval but never runs a flow as itself.
        new OpenBoxApprovalPoller().execute(null);
        Assert.areEqual(OpenBoxRequestStatus.APPROVED, [SELECT Status__c FROM OpenBox_Governed_Request__c].Status__c);
        Assert.areEqual(0, [SELECT COUNT() FROM Task WHERE Subject = 'Second call']);

        OpenBox_GovernedAction.Result checked;
        OpenBox_GovernedAction.Result again;
        System.runAs(OpenBoxTestData.agentUser()) {
            checked = OpenBoxConversationTest.check(requestNumber);
            again = OpenBoxConversationTest.check(requestNumber);
        }
        Test.stopTest();

        Assert.areEqual(OpenBoxRequestStatus.EXECUTED, checked.status, checked.message);
        Assert.areEqual(OpenBoxRequestStatus.EXECUTED, again.status, 'a checked call runs once');
        Assert.areEqual(1, [SELECT COUNT() FROM Task WHERE Subject = 'Second call']);
    }

    // ── Inside a governed conversation ──────────────────────────────────────────────────────

    @IsTest
    static void lookupIsAGovernedToolOfTheConversation() {
        OpenBoxTestData.useDefaultSettings();
        OpenBoxConversationTest.seedSession('Find Acme', 'discount_management');
        OpenBoxCoreMock core = OpenBoxCoreMock.install();
        OpenBox_FindOpportunity.Result found;
        System.runAs(OpenBoxTestData.agentUser()) {
            Test.startTest();
            OpenBox_FindOpportunity.Request lookup = new OpenBox_FindOpportunity.Request();
            lookup.nameQuery = 'Acme';
            lookup.conversationKey = KEY;
            found = OpenBox_FindOpportunity.find(new List<OpenBox_FindOpportunity.Request>{ lookup })[0];
            Test.stopTest();
        }
        Assert.areEqual(OpportunityDiscountTestData.opportunityNamed(ACME_NAME).Id, found.opportunityId, found.matches);
        Assert.areEqual(
            new List<String>{ 'ActivityStarted:find_opportunity', 'ActivityCompleted:find_opportunity' },
            core.eventSequence()
        );
    }

    @IsTest
    static void discountJoinsTheConversationAndLeavesItOpen() {
        OpenBoxTestData.useDefaultSettings();
        Id sessionId = OpenBoxConversationTest.seedSession('Set Acme to 10%', 'discount_management').Id;
        OpenBoxCoreMock core = OpenBoxCoreMock.install();
        Opportunity acme = OpportunityDiscountTestData.opportunityNamed(ACME_NAME);
        OpenBox_GovernedDiscountUpdate.Result result;
        System.runAs(OpenBoxTestData.agentUser()) {
            Test.startTest();
            OpenBox_GovernedDiscountUpdate.Request request = OpportunityDiscountTestData.request(acme.Id, 10, 'Renewal');
            request.agentSessionId = KEY;
            result = OpenBox_GovernedDiscountUpdate.updateDiscount(new List<OpenBox_GovernedDiscountUpdate.Request>{ request })[0];
            Test.stopTest();
        }
        Assert.areEqual(OpenBoxRequestStatus.EXECUTED, result.status, result.message);
        Assert.areEqual(0, core.eventsOfType('WorkflowStarted').size(), 'the discount joins the conversation');
        Assert.areEqual(0, core.eventsOfType('WorkflowCompleted').size(), 'and leaves it open');
        for (Map<String, Object> event : core.evaluated) {
            Assert.areEqual(RUN_ID, event.get('run_id'), 'every event is in the conversation\'s run');
        }
        Assert.areEqual(sessionId, [SELECT Agent_Session__c FROM OpenBox_Governed_Request__c].Agent_Session__c);
    }

    private static OpenBox_CheckDiscountApproval.Request reference(String value) {
        OpenBox_CheckDiscountApproval.Request request = new OpenBox_CheckDiscountApproval.Request();
        request.requestReference = value;
        return request;
    }
}
