/**
 * Governed record writes (OpenBoxRecordWriter through OpenBoxToolGovernance) against a scripted
 * OpenBox Core, using OpenBoxTestWriter on Opportunity.NextStep. Each test asserts the Salesforce
 * outcome, the audit trail and the governance events on the wire, including that every started
 * event and span is paired with its completion.
 */
@IsTest
private class OpenBoxRecordWriteTest {
    private static final String ACME_NAME = 'Acme renewal';
    private static final String GLOBEX_NAME = 'Globex expansion';
    private static final String ORIGINAL = 'Send proposal';
    private static final String KEY = 'record-write-conversation';
    private static final String RUN_ID = 'run-record-write';

    @TestSetup
    static void setup() {
        OpenBoxTestData.createCast();
    }

    // ── ALLOW ───────────────────────────────────────────────────────────────────────────────

    @IsTest
    static void allowWritesOnceAuditsAndClosesEveryPair() {
        OpenBoxTestData.useDefaultSettings();
        OpenBoxCoreMock core = OpenBoxCoreMock.install();
        Opportunity acme = OpenBoxTestData.opportunityNamed(ACME_NAME);
        OpenBoxToolGovernance.Result result;

        System.runAs(OpenBoxTestData.agentUser()) {
            Test.startTest();
            result = governOne(acme.Id, 'Book the kickoff');
            Test.stopTest();
        }

        Assert.areEqual(OpenBoxRequestStatus.EXECUTED, result.status, result.message);
        Assert.isTrue(result.executed);
        Assert.areEqual('ALLOW', result.verdict);
        Assert.areEqual(ORIGINAL, result.previousValues.get('NextStep'), 'the value before the change is reported');
        Assert.areEqual('Book the kickoff', result.changes.get('NextStep'));
        Assert.areEqual(acme.Id, result.recordId);
        assertNextStep(ACME_NAME, 'Book the kickoff');

        OpenBox_Governed_Request__c record = OpenBoxTestData.governedRequests()[0];
        Assert.areEqual('ALLOW', record.Decision__c);
        Assert.isNotNull(record.Decision_Id__c, 'decision id must be recorded');
        Assert.isNotNull(record.Executed_At__c);
        Assert.areEqual(acme.Id, record.Record_Id__c);
        Assert.areEqual(new List<String>{ 'Allowed', 'Executed' }, OpenBoxTestData.auditOutcomes());
        Assert.areEqual(
            new List<String>{
                'WorkflowStarted:Agentforce Sales Agent',
                'SignalReceived:user_prompt',
                'ActivityStarted:OpportunityLookup',
                'span:SELECT Opportunity:started',
                'span:SELECT Opportunity:completed',
                'ActivityCompleted:OpportunityLookup',
                'ActivityStarted:OpportunityNextStepUpdate',
                'span:SELECT Opportunity:started',
                'span:SELECT Opportunity:completed',
                'span:UPDATE Opportunity:started',
                'span:UPDATE Opportunity:completed',
                'ActivityCompleted:OpportunityNextStepUpdate',
                'WorkflowCompleted:Agentforce Sales Agent'
            },
            core.eventSequence(),
            'events must follow the OpenBox protocol order'
        );
        assertFullyPaired(core);

        Map<String, Object> decided = startOf(core, OpenBoxTestWriter.TOOL_NAME);
        Map<String, Object> facts = (Map<String, Object>) ((List<Object>) decided.get('activity_input'))[0];
        Assert.areEqual(false, facts.get('isclosed'), 'the writer\'s facts reach OpenBox');
        Assert.areEqual('Agreed on the last call', facts.get('justification'));
        Assert.isNotNull(facts.get('requested_change'));
        for (Map<String, Object> span : core.spans()) {
            if (span.get('name') == 'UPDATE Opportunity' && span.get('stage') == 'started') {
                Map<String, Object> attributes = (Map<String, Object>) span.get('attributes');
                Assert.areEqual('Prospecting', attributes.get('salesforce.opportunity.stage'), 'writer attributes are on the write span');
                Assert.areEqual('NextStep', attributes.get('salesforce.field'));
            }
        }
    }

    @IsTest
    static void callsOfOneTransactionAreAllDecidedBeforeAnyWrite() {
        OpenBoxTestData.useDefaultSettings();
        OpenBoxCoreMock.install();
        Opportunity acme = OpenBoxTestData.opportunityNamed(ACME_NAME);
        Opportunity globex = OpenBoxTestData.opportunityNamed(GLOBEX_NAME);
        List<OpenBoxToolGovernance.Result> results;

        // Globex is not the agent's, so the second write is to a record the admin owns.
        System.runAs(OpenBoxTestData.adminUser()) {
            Test.startTest();
            results = new OpenBoxToolGovernance()
                .governAll(
                    new List<OpenBoxToolGovernance.ToolCall>{
                        OpenBoxTestWriter.call(acme.Id, 'First'),
                        OpenBoxTestWriter.call(globex.Id, 'Second'),
                        OpenBoxTestWriter.call(acme.Id, 'Third')
                    }
                );
            Test.stopTest();
        }

        Assert.areEqual(OpenBoxRequestStatus.EXECUTED, results[0].status, results[0].message);
        Assert.areEqual(OpenBoxRequestStatus.EXECUTED, results[1].status, results[1].message);
        Assert.areEqual(OpenBoxRequestStatus.FAILED, results[2].status, 'a second change to one record is refused');
        Assert.isTrue(results[2].reason.contains('same transaction'), results[2].reason);
        assertNextStep(ACME_NAME, 'First');
        assertNextStep(GLOBEX_NAME, 'Second');
    }

    // ── BLOCK and HALT ──────────────────────────────────────────────────────────────────────

    @IsTest
    static void blockLeavesRecordUnchangedAndClosesRunAsFailed() {
        OpenBoxTestData.useDefaultSettings();
        OpenBoxCoreMock core = OpenBoxCoreMock.install().onActivityStarted(OpenBoxTestWriter.TOOL_NAME, 'block', 'Not today');
        Opportunity acme = OpenBoxTestData.opportunityNamed(ACME_NAME);
        OpenBoxToolGovernance.Result result;

        System.runAs(OpenBoxTestData.agentUser()) {
            Test.startTest();
            result = governOne(acme.Id, 'Book the kickoff');
            Test.stopTest();
        }

        Assert.areEqual(OpenBoxRequestStatus.BLOCKED, result.status);
        Assert.isFalse(result.executed);
        Assert.isTrue(result.message.contains('Not today'), result.message);
        assertNextStep(ACME_NAME, ORIGINAL);
        Assert.areEqual(new List<String>{ 'Blocked' }, OpenBoxTestData.auditOutcomes());
        Map<String, Object> completed = completionOf(core, OpenBoxTestWriter.TOOL_NAME);
        Assert.areEqual('failed', completed.get('status'));
        Assert.areEqual('GovernanceBlocked', ((Map<String, Object>) completed.get('error')).get('type'));
        Assert.areEqual(0, countSpans(core, 'UPDATE Opportunity'), 'no write span may be reported for a refused write');
        Assert.areEqual('failed', core.eventsOfType('WorkflowCompleted')[0].get('status'));
        assertFullyPaired(core);
    }

    @IsTest
    static void haltEndsTheRunWithWorkflowFailedAndNoWrite() {
        OpenBoxTestData.useDefaultSettings();
        OpenBoxCoreMock core = OpenBoxCoreMock.install().onActivityStarted(OpenBoxTestWriter.TOOL_NAME, 'halt', 'Abuse');
        Opportunity acme = OpenBoxTestData.opportunityNamed(ACME_NAME);
        OpenBoxToolGovernance.Result result;

        System.runAs(OpenBoxTestData.agentUser()) {
            Test.startTest();
            result = governOne(acme.Id, 'Book the kickoff');
            Test.stopTest();
        }

        Assert.areEqual(OpenBoxRequestStatus.HALTED, result.status);
        assertNextStep(ACME_NAME, ORIGINAL);
        Assert.areEqual('terminated', core.eventsOfType('WorkflowFailed')[0].get('status'));
        Assert.areEqual(0, core.eventsOfType('WorkflowCompleted').size(), 'after HALT only WorkflowFailed is sent');
    }

    @IsTest
    static void refusedLookupNeverReadsTheRecord() {
        OpenBoxTestData.useDefaultSettings();
        OpenBoxCoreMock core = OpenBoxCoreMock.install().onActivityStarted(OpenBoxTestWriter.LOOKUP, 'block', 'No reading');
        Opportunity acme = OpenBoxTestData.opportunityNamed(ACME_NAME);
        OpenBoxToolGovernance.Result result;

        System.runAs(OpenBoxTestData.agentUser()) {
            Test.startTest();
            result = governOne(acme.Id, 'Book the kickoff');
            Test.stopTest();
        }

        Assert.areEqual(OpenBoxRequestStatus.BLOCKED, result.status);
        Assert.areEqual(0, countSpans(core, 'SELECT Opportunity'), 'the read never happens');
        Assert.areEqual(0, core.eventsOfType('ActivityStarted').size() - 1, 'the write is never asked for');
        assertFullyPaired(core);
    }

    // ── REQUIRE_APPROVAL ────────────────────────────────────────────────────────────────────

    @IsTest
    static void approvalRequiredWaitsWithoutWriting() {
        OpenBoxTestData.useDefaultSettings();
        OpenBoxCoreMock core = OpenBoxCoreMock.install()
            .onActivityStarted(OpenBoxTestWriter.TOOL_NAME, 'require_approval', 'Needs a manager');
        Opportunity acme = OpenBoxTestData.opportunityNamed(ACME_NAME);
        OpenBoxToolGovernance.Result result;

        System.runAs(OpenBoxTestData.agentUser()) {
            Test.startTest();
            result = governOne(acme.Id, 'Book the kickoff');
            Test.stopTest();
        }

        Assert.areEqual(OpenBoxRequestStatus.PENDING, result.status);
        Assert.isNotNull(result.approvalExpiresAt);
        Assert.isTrue(result.message.contains(result.requestNumber), result.message);
        Assert.isTrue(result.message.contains('applied automatically'), result.message);
        assertNextStep(ACME_NAME, ORIGINAL);
        OpenBox_Governed_Request__c record = OpenBoxTestData.governedRequests()[0];
        Assert.areEqual(ORIGINAL, ((Map<String, Object>) JSON.deserializeUntyped(record.Baseline_Values__c)).get('NextStep'));
        Assert.areEqual(new List<String>{ 'Approval_Required' }, OpenBoxTestData.auditOutcomes());
        Assert.areEqual(0, core.eventsOfType('WorkflowCompleted').size(), 'the run stays open while a human decides');
        Assert.isFalse(core.approvalPolls.isEmpty(), 'the background poller is scheduled for the pending request');
    }

    @IsTest
    static void approvedWriteRunsOnceInALaterTransactionAndReplayIsANoOp() {
        OpenBoxTestData.useDefaultSettings();
        Opportunity acme = OpenBoxTestData.opportunityNamed(ACME_NAME);
        OpenBox_Governed_Request__c pending = pendingRequest(acme, 'Book the kickoff');
        OpenBoxCoreMock core = OpenBoxCoreMock.install().answerApproval('allow', 'Approved by a manager');

        Test.startTest();
        OpenBoxToolGovernance.Result first = resolve(pending.Id);
        Integer calloutsAfterFirst = core.requests.size();
        OpenBoxToolGovernance.Result replay = resolve(pending.Id);
        Assert.areEqual(calloutsAfterFirst, core.requests.size(), 'a replay must not contact OpenBox again');
        Test.stopTest();

        Assert.areEqual(OpenBoxRequestStatus.EXECUTED, first.status, first.message);
        Assert.areEqual(OpenBoxRequestStatus.EXECUTED, replay.status);
        assertNextStep(ACME_NAME, 'Book the kickoff');
        Assert.areEqual(1, [SELECT COUNT() FROM OpenBox_Governance_Audit__c WHERE Outcome__c = 'Executed'], 'at most one write');
        Assert.areEqual(pending.Activity_Id__c, core.approvalPolls[0].get('activity_id'));
        Map<String, Object> completion = completionOf(core, OpenBoxTestWriter.TOOL_NAME);
        Assert.areEqual(pending.Activity_Id__c, completion.get('activity_id'), 'the resumed run closes the original activity');
        Assert.areEqual('completed', completion.get('status'));
        Assert.areEqual('completed', core.eventsOfType('WorkflowCompleted')[0].get('status'), 'a run of its own is completed');
        assertSpansPaired(core);
    }

    @IsTest
    static void approvedWriteRunsFromThePoller() {
        OpenBoxTestData.useDefaultSettings();
        Opportunity acme = OpenBoxTestData.opportunityNamed(ACME_NAME);
        OpenBox_Governed_Request__c pending = pendingRequest(acme, 'Book the kickoff');
        OpenBoxCoreMock.install().answerApproval('allow', 'Approved');

        Test.startTest();
        System.enqueueJob(new OpenBoxApprovalPoller());
        Test.stopTest();

        Assert.areEqual(OpenBoxRequestStatus.EXECUTED, [SELECT Status__c FROM OpenBox_Governed_Request__c WHERE Id = :pending.Id].Status__c);
        assertNextStep(ACME_NAME, 'Book the kickoff');
    }

    @IsTest
    static void rejectedApprovalClosesTheRunWithoutWriting() {
        assertApprovalTerminal('halt', 'Rejected by finance', OpenBoxRequestStatus.REJECTED, 'ApprovalRejected');
    }

    @IsTest
    static void expiredApprovalClosesTheRunWithoutWriting() {
        assertApprovalTerminal('halt', 'approval request expired', OpenBoxRequestStatus.EXPIRED, 'ApprovalExpired');
    }

    @IsTest
    static void stillPendingApprovalChangesNothing() {
        OpenBoxTestData.useDefaultSettings();
        Opportunity acme = OpenBoxTestData.opportunityNamed(ACME_NAME);
        OpenBox_Governed_Request__c pending = pendingRequest(acme, 'Book the kickoff');
        OpenBoxCoreMock core = OpenBoxCoreMock.install().answerApproval('require_approval', null);

        Test.startTest();
        OpenBoxToolGovernance.Result result = resolve(pending.Id);
        Test.stopTest();

        Assert.areEqual(OpenBoxRequestStatus.PENDING, result.status);
        assertNextStep(ACME_NAME, ORIGINAL);
        Assert.areEqual(0, core.evaluated.size(), 'polling a pending approval emits no governance events');
        Assert.isTrue([SELECT Poll_Count__c FROM OpenBox_Governed_Request__c WHERE Id = :pending.Id].Poll_Count__c == 1);
    }

    @IsTest
    static void recordEditedWhileAwaitingApprovalIsRefusedAsStale() {
        OpenBoxTestData.useDefaultSettings();
        Opportunity acme = OpenBoxTestData.opportunityNamed(ACME_NAME);
        OpenBox_Governed_Request__c pending = pendingRequest(acme, 'Book the kickoff');
        System.runAs(OpenBoxTestData.adminUser()) {
            update new Opportunity(Id = acme.Id, NextStep = 'Changed by a human');
        }
        OpenBoxCoreMock core = OpenBoxCoreMock.install().answerApproval('allow', 'Approved');

        Test.startTest();
        OpenBoxToolGovernance.Result result = resolve(pending.Id);
        Test.stopTest();

        Assert.areEqual(OpenBoxRequestStatus.STALE, result.status, result.reason);
        assertNextStep(ACME_NAME, 'Changed by a human');
        Assert.areEqual(0, countSpans(core, 'UPDATE Opportunity'), 'no write is attempted for a stale record');
        Assert.areEqual(
            'StaleRecord',
            ((Map<String, Object>) completionOf(core, OpenBoxTestWriter.TOOL_NAME).get('error')).get('type')
        );
    }

    // ── OpenBox unavailable ─────────────────────────────────────────────────────────────────

    @IsTest
    static void unavailableOpenBoxFailsClosed() {
        OpenBoxTestData.useDefaultSettings();
        OpenBoxCoreMock core = OpenBoxCoreMock.install().failNext(10, 503);
        Opportunity acme = OpenBoxTestData.opportunityNamed(ACME_NAME);
        OpenBoxToolGovernance.Result result;

        System.runAs(OpenBoxTestData.agentUser()) {
            Test.startTest();
            result = governOne(acme.Id, 'Book the kickoff');
            core.healthy();
            Test.stopTest();
        }

        Assert.areEqual(OpenBoxRequestStatus.FAILED, result.status, result.message);
        Assert.areEqual('ERROR', result.verdict);
        Assert.isFalse(result.executed);
        assertNextStep(ACME_NAME, ORIGINAL);
        Assert.areEqual(new List<String>{ 'Governance_Unavailable' }, OpenBoxTestData.auditOutcomes());
    }

    // ── Salesforce access ───────────────────────────────────────────────────────────────────

    @IsTest
    static void salesforceAccessIsEnforcedEvenWhenOpenBoxAllows() {
        OpenBoxTestData.useDefaultSettings();
        OpenBoxCoreMock core = OpenBoxCoreMock.install();
        Opportunity globex = OpenBoxTestData.opportunityNamed(GLOBEX_NAME);
        OpenBoxToolGovernance.Result result;

        System.runAs(OpenBoxTestData.readOnlyUser()) {
            Test.startTest();
            result = governOne(globex.Id, 'Book the kickoff');
            Test.stopTest();
        }

        Assert.areEqual('ALLOW', result.verdict, 'OpenBox allowed the change');
        Assert.areEqual(OpenBoxRequestStatus.PERMISSION_DENIED, result.status, result.message);
        Assert.isTrue(result.reason.contains('cannot edit Opportunity'), result.reason);
        assertNextStep(GLOBEX_NAME, ORIGINAL);
        Assert.areEqual(new List<String>{ 'Allowed', 'Permission_Denied' }, OpenBoxTestData.auditOutcomes());
        assertFullyPaired(core);
    }

    @IsTest
    static void unentitledUserIsRefusedBeforeContactingOpenBox() {
        OpenBoxTestData.useDefaultSettings();
        OpenBoxCoreMock core = OpenBoxCoreMock.install();
        Opportunity acme = OpenBoxTestData.opportunityNamed(ACME_NAME);
        OpenBoxToolGovernance.Result result;

        System.runAs(OpenBoxTestData.outsiderUser()) {
            Test.startTest();
            result = governOne(acme.Id, 'Book the kickoff');
            Test.stopTest();
        }

        Assert.areEqual(OpenBoxRequestStatus.PERMISSION_DENIED, result.status);
        Assert.isTrue(result.reason.contains(OpenBoxAccess.DEFAULT_PERMISSION), result.reason);
        Assert.areEqual(0, core.requests.size(), 'no governance session is opened for an unentitled caller');
    }

    @IsTest
    static void businessRuleRefusesTheWriteAfterTheDecision() {
        OpenBoxTestData.useDefaultSettings();
        Opportunity acme = OpenBoxTestData.opportunityNamed(ACME_NAME);
        System.runAs(OpenBoxTestData.adminUser()) {
            update new Opportunity(Id = acme.Id, StageName = 'Closed Lost');
        }
        OpenBoxCoreMock.install();
        OpenBoxToolGovernance.Result result;

        System.runAs(OpenBoxTestData.agentUser()) {
            Test.startTest();
            result = governOne(acme.Id, 'Book the kickoff');
            Test.stopTest();
        }

        Assert.areEqual(OpenBoxRequestStatus.FAILED, result.status);
        Assert.areEqual('Closed Opportunities are not changed', result.reason);
        assertNextStep(ACME_NAME, ORIGINAL);
    }

    // ── Behaviour rules ─────────────────────────────────────────────────────────────────────

    @IsTest
    static void behaviourRuleBlockOnTheWriteSpanPreventsTheWrite() {
        OpenBoxTestData.useDefaultSettings();
        OpenBoxCoreMock core = OpenBoxCoreMock.install().onSpanStarted('UPDATE', 'block', 'Behavioral violation: no locked read');
        Opportunity acme = OpenBoxTestData.opportunityNamed(ACME_NAME);
        OpenBoxToolGovernance.Result result;

        System.runAs(OpenBoxTestData.agentUser()) {
            Test.startTest();
            result = governOne(acme.Id, 'Book the kickoff');
            Test.stopTest();
        }

        Assert.areEqual(OpenBoxRequestStatus.BLOCKED, result.status);
        assertNextStep(ACME_NAME, ORIGINAL);
        Assert.areEqual(2, countSpans(core, 'UPDATE Opportunity'), 'the refused write span is still closed');
        Assert.areEqual('failed', completionOf(core, OpenBoxTestWriter.TOOL_NAME).get('status'));
        assertFullyPaired(core);
    }

    @IsTest
    static void behaviourRuleApprovalOnTheWriteSpanWaits() {
        OpenBoxTestData.useDefaultSettings();
        OpenBoxCoreMock core = OpenBoxCoreMock.install().onSpanStarted('UPDATE', 'require_approval', 'Behavioral violation: sign-off');
        Opportunity acme = OpenBoxTestData.opportunityNamed(ACME_NAME);
        OpenBoxToolGovernance.Result result;

        System.runAs(OpenBoxTestData.agentUser()) {
            Test.startTest();
            result = governOne(acme.Id, 'Book the kickoff');
            Test.stopTest();
        }

        Assert.areEqual(OpenBoxRequestStatus.PENDING, result.status);
        Assert.areEqual('REQUIRE_APPROVAL', result.verdict);
        assertNextStep(ACME_NAME, ORIGINAL);
        assertSpansPaired(core);
    }

    // ── Guardrails ──────────────────────────────────────────────────────────────────────────

    @IsTest
    static void inputGuardrailRedactionIsWhatSalesforceStores() {
        OpenBoxTestData.useDefaultSettings();
        OpenBoxCoreMock.install()
            .onActivityStarted(
                OpenBoxTestWriter.TOOL_NAME,
                new Map<String, Object>{
                    'verdict' => 'allow',
                    'action' => 'allow',
                    'guardrails_result' => new Map<String, Object>{
                        'validation_passed' => true,
                        'input_type' => 'activity_input',
                        'redacted_input' => new List<Object>{
                            new Map<String, Object>{ 'justification' => 'Call <EMAIL_ADDRESS> to confirm' }
                        },
                        'reasons' => new List<Object>()
                    }
                }
            );
        Opportunity acme = OpenBoxTestData.opportunityNamed(ACME_NAME);
        OpenBoxToolGovernance.ToolCall call = OpenBoxTestWriter.call(acme.Id, 'Book the kickoff');
        call.justification = 'Call jane.doe@example.com to confirm';

        System.runAs(OpenBoxTestData.agentUser()) {
            Test.startTest();
            new OpenBoxToolGovernance().govern(call);
            Test.stopTest();
        }

        Assert.areEqual('Call <EMAIL_ADDRESS> to confirm', OpenBoxTestData.governedRequests()[0].Justification__c);
    }

    @IsTest
    static void outputGuardrailRedactsWhatTheAgentIsTold() {
        OpenBoxTestData.useDefaultSettings();
        OpenBoxCoreMock.install()
            .onActivityCompleted(
                OpenBoxTestWriter.LOOKUP,
                new Map<String, Object>{
                    'verdict' => 'allow',
                    'action' => 'allow',
                    'guardrails_result' => new Map<String, Object>{
                        'validation_passed' => true,
                        'input_type' => 'activity_output',
                        'redacted_input' => new Map<String, Object>{ 'description' => 'Primary contact <EMAIL_ADDRESS>' },
                        'reasons' => new List<Object>()
                    }
                }
            );
        Opportunity acme = OpenBoxTestData.opportunityNamed(ACME_NAME);
        OpenBoxToolGovernance.Result result;

        System.runAs(OpenBoxTestData.agentUser()) {
            Test.startTest();
            result = governOne(acme.Id, 'Book the kickoff');
            Test.stopTest();
        }

        Assert.isTrue(result.summary.contains('<EMAIL_ADDRESS>'), result.summary);
        Assert.isFalse(result.summary.contains('jane.doe@example.com'), 'unredacted personal data must not reach the agent');
    }

    // ── Validation and limits ───────────────────────────────────────────────────────────────

    @IsTest
    static void invalidInputsAreRefusedWithoutContactingOpenBox() {
        OpenBoxTestData.useDefaultSettings();
        OpenBoxCoreMock core = OpenBoxCoreMock.install();
        Opportunity acme = OpenBoxTestData.opportunityNamed(ACME_NAME);
        List<OpenBoxToolGovernance.Result> results;

        System.runAs(OpenBoxTestData.agentUser()) {
            Test.startTest();
            results = new OpenBoxToolGovernance()
                .governAll(
                    new List<OpenBoxToolGovernance.ToolCall>{
                        OpenBoxTestWriter.call(acme.Id, ''),
                        OpenBoxTestWriter.call(UserInfo.getUserId(), 'Wrong object'),
                        OpenBoxTestWriter.call(null, 'No record')
                    }
                );
            Test.stopTest();
        }

        for (OpenBoxToolGovernance.Result result : results) {
            Assert.areEqual(OpenBoxRequestStatus.FAILED, result.status, result.message);
            Assert.isFalse(result.executed);
        }
        Assert.areEqual('next_step is required', results[0].reason);
        Assert.areEqual(0, core.requests.size());
        Assert.areEqual(3, [SELECT COUNT() FROM OpenBox_Governance_Audit__c WHERE Outcome__c = 'Invalid_Request']);
    }

    @IsTest
    static void callsBeyondThePerTransactionLimitAreRefused() {
        OpenBoxTestData.useDefaultSettings();
        OpenBoxCoreMock.install().onActivityStarted(OpenBoxTestWriter.TOOL_NAME, 'block', 'Not now');
        Opportunity acme = OpenBoxTestData.opportunityNamed(ACME_NAME);
        List<OpenBoxToolGovernance.ToolCall> calls = new List<OpenBoxToolGovernance.ToolCall>();
        for (Integer i = 0; i < 6; i++) {
            calls.add(OpenBoxTestWriter.call(acme.Id, 'Step ' + i));
        }
        List<OpenBoxToolGovernance.Result> results;

        System.runAs(OpenBoxTestData.agentUser()) {
            Test.startTest();
            results = new OpenBoxToolGovernance().governAll(calls);
            Test.stopTest();
        }

        Assert.areEqual(6, results.size());
        Assert.areEqual(OpenBoxRequestStatus.BLOCKED, results[4].status);
        Assert.areEqual(OpenBoxRequestStatus.FAILED, results[5].status);
        Assert.isTrue(results[5].reason.contains('At most 5'), results[5].reason);
    }

    // ── Conversations ───────────────────────────────────────────────────────────────────────

    @IsTest
    static void writeJoinsItsConversationAndLeavesItOpen() {
        OpenBoxTestData.useDefaultSettings();
        OpenBox_Agent_Session__c session = seedSession();
        OpenBoxCoreMock core = OpenBoxCoreMock.install();
        Opportunity acme = OpenBoxTestData.opportunityNamed(ACME_NAME);
        OpenBoxToolGovernance.Result result;

        System.runAs(OpenBoxTestData.agentUser()) {
            Test.startTest();
            OpenBoxToolGovernance.ToolCall call = OpenBoxTestWriter.call(acme.Id, 'Book the kickoff');
            call.sessionKey = KEY;
            result = new OpenBoxToolGovernance().govern(call);
            Test.stopTest();
        }

        Assert.areEqual(OpenBoxRequestStatus.EXECUTED, result.status, result.message);
        Assert.areEqual(KEY, result.sessionKey);
        Assert.areEqual(0, core.eventsOfType('WorkflowStarted').size(), 'the write joins the conversation');
        Assert.areEqual(0, core.eventsOfType('WorkflowCompleted').size(), 'and leaves it open');
        Assert.areEqual(0, core.eventsOfType('SignalReceived').size(), 'the message was already governed by the gate');
        for (Map<String, Object> event : core.evaluated) {
            Assert.areEqual(RUN_ID, event.get('run_id'), 'every event is in the conversation\'s run');
        }
        Assert.areEqual(session.Id, [SELECT Agent_Session__c FROM OpenBox_Governed_Request__c].Agent_Session__c);
    }

    @IsTest
    static void writeInAHaltedConversationIsRefused() {
        OpenBoxTestData.useDefaultSettings();
        OpenBox_Agent_Session__c session = seedSession();
        session.Status__c = OpenBoxAgentSession.STATUS_HALTED;
        update session;
        OpenBoxCoreMock core = OpenBoxCoreMock.install();
        Opportunity acme = OpenBoxTestData.opportunityNamed(ACME_NAME);
        OpenBoxToolGovernance.Result result;

        System.runAs(OpenBoxTestData.agentUser()) {
            Test.startTest();
            OpenBoxToolGovernance.ToolCall call = OpenBoxTestWriter.call(acme.Id, 'Book the kickoff');
            call.sessionKey = KEY;
            result = new OpenBoxToolGovernance().govern(call);
            Test.stopTest();
        }

        Assert.areEqual(OpenBoxRequestStatus.HALTED, result.status);
        Assert.areEqual(0, core.requests.size());
        assertNextStep(ACME_NAME, ORIGINAL);
    }

    @IsTest
    static void approvedWriteOfAConversationClosesTheFinishedTurn() {
        OpenBoxTestData.useDefaultSettings();
        OpenBox_Agent_Session__c session = seedSession();
        Opportunity acme = OpenBoxTestData.opportunityNamed(ACME_NAME);
        OpenBox_Governed_Request__c pending = pendingRequest(acme, 'Book the kickoff');
        pending.Agent_Session__c = session.Id;
        pending.Workflow_Id__c = session.Workflow_Id__c;
        pending.Run_Id__c = RUN_ID;
        update pending;
        // The turn that asked has ended: the conversation has moved on to another run.
        session.Run_Id__c = 'run-next-turn';
        update session;
        OpenBoxCoreMock core = OpenBoxCoreMock.install().answerApproval('allow', 'Approved');

        Test.startTest();
        OpenBoxToolGovernance.Result result = resolve(pending.Id);
        Test.stopTest();

        Assert.areEqual(OpenBoxRequestStatus.EXECUTED, result.status, result.message);
        Map<String, Object> closed = core.eventsOfType('WorkflowCompleted')[0];
        Assert.areEqual(RUN_ID, closed.get('run_id'), 'the turn that waited is closed now');
        Assert.areEqual('completed', closed.get('status'));
    }

    // ── Helpers ─────────────────────────────────────────────────────────────────────────────

    private static OpenBoxToolGovernance.Result governOne(Id recordId, String nextStep) {
        return new OpenBoxToolGovernance().govern(OpenBoxTestWriter.call(recordId, nextStep));
    }

    private static OpenBoxToolGovernance.Result resolve(Id requestId) {
        return new OpenBoxToolGovernance().resolve(new Set<Id>{ requestId }, false)[0];
    }

    private static void assertNextStep(String opportunityName, String expected) {
        Assert.areEqual(expected, OpenBoxTestData.opportunityNamed(opportunityName).NextStep);
    }

    private static void assertApprovalTerminal(String action, String reason, String expectedStatus, String expectedErrorType) {
        OpenBoxTestData.useDefaultSettings();
        Opportunity acme = OpenBoxTestData.opportunityNamed(ACME_NAME);
        OpenBox_Governed_Request__c pending = pendingRequest(acme, 'Book the kickoff');
        OpenBoxCoreMock core = OpenBoxCoreMock.install().answerApproval(action, reason);

        Test.startTest();
        OpenBoxToolGovernance.Result result = resolve(pending.Id);
        Test.stopTest();

        Assert.areEqual(expectedStatus, result.status);
        Assert.isFalse(result.executed);
        assertNextStep(ACME_NAME, ORIGINAL);
        Map<String, Object> completion = completionOf(core, OpenBoxTestWriter.TOOL_NAME);
        Assert.areEqual(pending.Activity_Id__c, completion.get('activity_id'));
        Assert.areEqual(expectedErrorType, ((Map<String, Object>) completion.get('error')).get('type'));
        Assert.areEqual('failed', core.eventsOfType('WorkflowCompleted')[0].get('status'));
    }

    /**
     * A write as the authorizing transaction would have left it: decided REQUIRE_APPROVAL, with the
     * run's correlation ids and the baseline recorded and nothing written.
     */
    private static OpenBox_Governed_Request__c pendingRequest(Opportunity opportunity, String nextStep) {
        String requestId = UUID.randomUUID().toString();
        OpenBox_Governed_Request__c record = new OpenBox_Governed_Request__c(
            Request_Id__c = requestId,
            Action__c = OpenBoxTestWriter.TOOL_NAME,
            Tool_Name__c = OpenBoxTestWriter.TOOL_NAME,
            Tool_Input__c = JSON.serialize(new Map<String, Object>{ 'record_id' => opportunity.Id, 'next_step' => nextStep }),
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
            Requested_By__c = OpenBoxTestData.agentUser().Id,
            Approval_Expires_At__c = Datetime.now().addMinutes(30),
            Next_Event_Sequence__c = 0,
            Poll_Count__c = 0
        );
        insert record;
        return record;
    }

    private static OpenBox_Agent_Session__c seedSession() {
        OpenBox_Agent_Session__c session = new OpenBox_Agent_Session__c(
            Session_Key__c = KEY,
            Workflow_Id__c = 'salesforce-conversation-' + KEY,
            Run_Id__c = RUN_ID,
            Trace_Id__c = OpenBoxIds.newTraceId(),
            Status__c = OpenBoxAgentSession.STATUS_ACTIVE,
            Turn_Count__c = 1,
            Goal__c = 'Set the next step',
            Started_At__c = Datetime.now(),
            Last_Activity_At__c = Datetime.now(),
            Next_Event_Sequence__c = 0,
            Requested_By__c = OpenBoxTestData.agentUser().Id
        );
        insert session;
        return session;
    }

    private static Map<String, Object> startOf(OpenBoxCoreMock core, String activityType) {
        for (Map<String, Object> event : core.eventsOfType('ActivityStarted')) {
            if (event.get('activity_type') == activityType && event.get('hook_trigger') != true) {
                return event;
            }
        }
        Assert.fail('no ActivityStarted for ' + activityType + ' in ' + core.eventSequence());
        return null;
    }

    private static Map<String, Object> completionOf(OpenBoxCoreMock core, String activityType) {
        for (Map<String, Object> event : core.eventsOfType('ActivityCompleted')) {
            if (event.get('activity_type') == activityType) {
                return event;
            }
        }
        Assert.fail('no ActivityCompleted for ' + activityType + ' in ' + core.eventSequence());
        return null;
    }

    private static Integer countSpans(OpenBoxCoreMock core, String name) {
        Integer count = 0;
        for (Map<String, Object> span : core.spans()) {
            if (span.get('name') == name) {
                count++;
            }
        }
        return count;
    }

    /** The OpenBox pairing invariants for a run that has ended. */
    private static void assertFullyPaired(OpenBoxCoreMock core) {
        Assert.areEqual(1, core.eventsOfType('WorkflowStarted').size(), 'exactly one WorkflowStarted');
        Assert.areEqual(
            1,
            core.eventsOfType('WorkflowCompleted').size() + core.eventsOfType('WorkflowFailed').size(),
            'exactly one terminal workflow event'
        );
        Map<String, Integer> open = new Map<String, Integer>();
        for (Map<String, Object> started : core.eventsOfType('ActivityStarted')) {
            if (started.get('hook_trigger') != true) {
                open.put((String) started.get('activity_id'), 1);
            }
        }
        for (Map<String, Object> completed : core.eventsOfType('ActivityCompleted')) {
            String activityId = (String) completed.get('activity_id');
            Assert.isTrue(open.containsKey(activityId), 'ActivityCompleted without ActivityStarted: ' + activityId);
            open.put(activityId, open.get(activityId) - 1);
        }
        for (String activityId : open.keySet()) {
            Assert.areEqual(0, open.get(activityId), 'activity not closed exactly once: ' + activityId);
        }
        assertSpansPaired(core);
    }

    private static void assertSpansPaired(OpenBoxCoreMock core) {
        Map<String, List<String>> stagesBySpan = new Map<String, List<String>>();
        for (Map<String, Object> span : core.spans()) {
            String spanId = (String) span.get('span_id');
            if (!stagesBySpan.containsKey(spanId)) {
                stagesBySpan.put(spanId, new List<String>());
            }
            stagesBySpan.get(spanId).add((String) span.get('stage'));
        }
        for (String spanId : stagesBySpan.keySet()) {
            Assert.areEqual(new List<String>{ 'started', 'completed' }, stagesBySpan.get(spanId), 'span ' + spanId);
        }
    }
}
