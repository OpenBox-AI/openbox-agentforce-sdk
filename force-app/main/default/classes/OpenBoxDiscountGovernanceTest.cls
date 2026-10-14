/**
 * Acceptance tests for the governed discount action (PRD section 7), driven against a scripted
 * OpenBox Core. Each test asserts the Salesforce outcome, the audit trail and the governance events
 * on the wire, including that every started event and span is paired with its completion.
 */
@IsTest
private class OpenBoxDiscountGovernanceTest {
    private static final String ACME_NAME = 'Acme renewal';
    private static final String GLOBEX_NAME = 'Globex expansion';

    @TestSetup
    static void setup() {
        OpenBoxTestData.createCast();
    }

    // ── ALLOW ───────────────────────────────────────────────────────────────────────────────

    @IsTest
    static void allowUpdatesOnceAuditsAndClosesEveryPair() {
        OpenBoxTestData.useDefaultSettings();
        OpenBoxCoreMock core = OpenBoxCoreMock.install();
        Opportunity acme = OpenBoxTestData.opportunityNamed(ACME_NAME);
        OpenBoxDiscountGovernance.Outcome outcome;

        System.runAs(OpenBoxTestData.agentUser()) {
            Test.startTest();
            outcome = new OpenBoxDiscountGovernance()
                .requestDiscounts(
                    new List<OpenBoxDiscountGovernance.DiscountRequest>{
                        OpenBoxTestData.request(acme.Id, 10, 'Multi-year renewal')
                    }
                )[0];
            Test.stopTest();
        }

        Assert.areEqual(OpenBoxDiscountGovernance.STATUS_EXECUTED, outcome.status, outcome.message);
        Assert.isTrue(outcome.changed);
        Assert.areEqual('ALLOW', outcome.decision);
        Assert.isTrue(outcome.previousDiscount == 5, 'previous discount is reported');
        assertDiscount(ACME_NAME, 10);

        OpenBox_Governed_Request__c record = OpenBoxTestData.governedRequests()[0];
        Assert.areEqual('ALLOW', record.Decision__c);
        Assert.isNotNull(record.Decision_Id__c, 'decision id must be recorded');
        Assert.isNotNull(record.Executed_At__c);
        Assert.areEqual(new List<String>{ 'Allowed', 'Executed' }, OpenBoxTestData.auditOutcomes());

        Assert.areEqual(
            new List<String>{
                'WorkflowStarted:Agentforce Sales Agent',
                'SignalReceived:user_prompt',
                'ActivityStarted:OpportunityLookup',
                'span:SELECT Opportunity:started',
                'span:SELECT Opportunity:completed',
                'ActivityCompleted:OpportunityLookup',
                'ActivityStarted:OpportunityDiscountUpdate',
                'span:SELECT Opportunity:started',
                'span:SELECT Opportunity:completed',
                'span:UPDATE Opportunity:started',
                'span:UPDATE Opportunity:completed',
                'ActivityCompleted:OpportunityDiscountUpdate',
                'WorkflowCompleted:Agentforce Sales Agent'
            },
            core.eventSequence(),
            'events must follow the OpenBox protocol order'
        );
        assertFullyPaired(core);
        Assert.areEqual(
            'completed',
            core.eventsOfType('WorkflowCompleted')[0].get('status'),
            'a successful run completes with status completed'
        );
        for (OpenBox_Event_Outbox__c row : [SELECT Status__c FROM OpenBox_Event_Outbox__c]) {
            Assert.areEqual(OpenBoxOutbox.STATUS_SENT, row.Status__c, 'post-write events are delivered by the outbox');
        }
    }

    // ── BLOCK ───────────────────────────────────────────────────────────────────────────────

    @IsTest
    static void blockLeavesRecordUnchangedAndClosesRunAsFailed() {
        OpenBoxTestData.useDefaultSettings();
        OpenBoxCoreMock core = OpenBoxCoreMock.install()
            .onActivityStarted(OpenBoxDiscountGovernance.ACTIVITY_UPDATE, 'block', 'Discounts above 40% are forbidden');
        Opportunity acme = OpenBoxTestData.opportunityNamed(ACME_NAME);
        OpenBoxDiscountGovernance.Outcome outcome;

        System.runAs(OpenBoxTestData.agentUser()) {
            Test.startTest();
            outcome = governOne(acme.Id, 55);
            Test.stopTest();
        }

        Assert.areEqual(OpenBoxDiscountGovernance.STATUS_BLOCKED, outcome.status);
        Assert.isFalse(outcome.changed);
        Assert.isTrue(outcome.message.contains('Discounts above 40% are forbidden'), outcome.message);
        assertDiscount(ACME_NAME, 5, 'a blocked request must not write');
        Assert.areEqual(new List<String>{ 'Blocked' }, OpenBoxTestData.auditOutcomes());

        Map<String, Object> updateCompleted = completionOf(core, OpenBoxDiscountGovernance.ACTIVITY_UPDATE);
        Assert.areEqual('failed', updateCompleted.get('status'));
        Assert.areEqual('GovernanceBlocked', ((Map<String, Object>) updateCompleted.get('error')).get('type'));
        Assert.areEqual(0, countSpans(core, 'UPDATE Opportunity'), 'no write span may be reported for a refused write');
        Assert.areEqual('failed', core.eventsOfType('WorkflowCompleted')[0].get('status'));
        assertFullyPaired(core);
    }

    // ── HALT ────────────────────────────────────────────────────────────────────────────────

    @IsTest
    static void haltEndsSessionWithWorkflowFailedAndNoWrite() {
        OpenBoxTestData.useDefaultSettings();
        OpenBoxCoreMock core = OpenBoxCoreMock.install()
            .onActivityStarted(
                OpenBoxDiscountGovernance.ACTIVITY_UPDATE,
                'halt',
                'Abusive discount; agent session halted'
            );
        Opportunity acme = OpenBoxTestData.opportunityNamed(ACME_NAME);
        OpenBoxDiscountGovernance.Outcome outcome;

        System.runAs(OpenBoxTestData.agentUser()) {
            Test.startTest();
            outcome = governOne(acme.Id, 95);
            Test.stopTest();
        }

        Assert.areEqual(OpenBoxDiscountGovernance.STATUS_HALTED, outcome.status);
        assertDiscount(ACME_NAME, 5);
        Assert.areEqual(1, core.eventsOfType('WorkflowFailed').size());
        Map<String, Object> failed = core.eventsOfType('WorkflowFailed')[0];
        Assert.areEqual('terminated', failed.get('status'));
        Assert.areEqual(
            0,
            core.eventsOfType('WorkflowCompleted').size(),
            'after HALT, Core closes the session; only WorkflowFailed is sent'
        );
        List<String> sequence = core.eventSequence();
        Assert.areEqual('WorkflowFailed:Agentforce Sales Agent', sequence[sequence.size() - 1]);
    }

    // ── REQUIRE_APPROVAL ────────────────────────────────────────────────────────────────────

    @IsTest
    static void approvalRequiredPersistsPendingRequestWithoutWriting() {
        OpenBoxTestData.useDefaultSettings();
        OpenBoxCoreMock core = OpenBoxCoreMock.install()
            .onActivityStarted(
                OpenBoxDiscountGovernance.ACTIVITY_UPDATE,
                'require_approval',
                'Discounts over 15% need sales-ops approval'
            );
        Opportunity acme = OpenBoxTestData.opportunityNamed(ACME_NAME);
        OpenBoxDiscountGovernance.Outcome outcome;

        System.runAs(OpenBoxTestData.agentUser()) {
            Test.startTest();
            outcome = governOne(acme.Id, 25);
            Test.stopTest();
        }

        Assert.areEqual(OpenBoxDiscountGovernance.STATUS_PENDING, outcome.status);
        Assert.isFalse(outcome.changed);
        Assert.isNotNull(outcome.approvalExpiresAt);
        Assert.isTrue(outcome.message.contains(outcome.requestNumber), outcome.message);
        assertDiscount(ACME_NAME, 5, 'nothing changes before approval');

        OpenBox_Governed_Request__c record = OpenBoxTestData.governedRequests()[0];
        Assert.areEqual(OpenBoxDiscountGovernance.STATUS_PENDING, record.Status__c);
        Assert.isNotNull(record.Activity_Id__c, 'the approval is keyed on the update activity id');
        Assert.areEqual(new List<String>{ 'Approval_Required' }, OpenBoxTestData.auditOutcomes());
        Assert.areEqual(0, core.eventsOfType('WorkflowCompleted').size(), 'the run stays open while a human decides');
        Assert.isFalse(core.approvalPolls.isEmpty(), 'the background poller must be scheduled for the pending request');
    }

    @IsTest
    static void approvedRequestExecutesOnceInLaterTransactionAndReplayIsNoOp() {
        OpenBoxTestData.useDefaultSettings();
        Opportunity acme = OpenBoxTestData.opportunityNamed(ACME_NAME);
        OpenBox_Governed_Request__c pending = pendingRequest(acme, 25);
        OpenBoxCoreMock core = OpenBoxCoreMock.install().answerApproval('allow', 'Approved by sales ops');
        List<OpenBoxDiscountGovernance.Outcome> first;
        List<OpenBoxDiscountGovernance.Outcome> replay;

        Test.startTest();
        first = new OpenBoxDiscountGovernance().resolvePending(new Set<Id>{ pending.Id });
        Integer calloutsAfterFirst = core.requests.size();
        replay = new OpenBoxDiscountGovernance().resolvePending(new Set<Id>{ pending.Id });
        Assert.areEqual(calloutsAfterFirst, core.requests.size(), 'a replay must not contact OpenBox again');
        Test.stopTest();

        Assert.areEqual(OpenBoxDiscountGovernance.STATUS_EXECUTED, first[0].status, first[0].message);
        Assert.areEqual(OpenBoxDiscountGovernance.STATUS_EXECUTED, replay[0].status);
        assertDiscount(ACME_NAME, 25);
        Assert.areEqual(
            1,
            [SELECT COUNT() FROM OpenBox_Governance_Audit__c WHERE Outcome__c = 'Executed'],
            'at most one committed mutation'
        );
        Assert.areEqual(
            pending.Activity_Id__c,
            core.approvalPolls[0].get('activity_id'),
            'the poll addresses the activity that requested approval'
        );

        Map<String, Object> completion = completionOf(core, OpenBoxDiscountGovernance.ACTIVITY_UPDATE);
        Assert.areEqual(
            pending.Activity_Id__c,
            completion.get('activity_id'),
            'the resumed run closes the original activity'
        );
        Assert.areEqual(pending.Workflow_Id__c, completion.get('workflow_id'));
        Assert.areEqual('completed', completion.get('status'));
        assertSpansPaired(core);
    }

    @IsTest
    static void rejectedApprovalClosesRunWithoutWriting() {
        assertApprovalTerminal(
            'halt',
            'Rejected by finance',
            OpenBoxDiscountGovernance.STATUS_REJECTED,
            'ApprovalRejected'
        );
    }

    @IsTest
    static void expiredApprovalClosesRunWithoutWriting() {
        assertApprovalTerminal(
            'halt',
            'approval request expired',
            OpenBoxDiscountGovernance.STATUS_EXPIRED,
            'ApprovalExpired'
        );
    }

    @IsTest
    static void pendingApprovalPastExpiryIsTreatedAsExpired() {
        OpenBoxTestData.useDefaultSettings();
        Opportunity acme = OpenBoxTestData.opportunityNamed(ACME_NAME);
        OpenBox_Governed_Request__c pending = pendingRequest(acme, 25);
        OpenBoxCoreMock core = OpenBoxCoreMock.install();
        Map<String, Object> lapsed = new Map<String, Object>{
            'id' => UUID.randomUUID().toString(),
            'action' => 'require_approval',
            'approval_expiration_time' => OpenBoxIds.timestamp(Datetime.now().addMinutes(-1))
        };
        core.answerRaw(JSON.serialize(lapsed));

        Test.startTest();
        OpenBoxDiscountGovernance.Outcome outcome = new OpenBoxDiscountGovernance()
            .resolvePending(new Set<Id>{ pending.Id })[0];
        Test.stopTest();

        Assert.areEqual(OpenBoxDiscountGovernance.STATUS_EXPIRED, outcome.status);
        assertDiscount(ACME_NAME, 5);
    }

    @IsTest
    static void stillPendingApprovalChangesNothing() {
        OpenBoxTestData.useDefaultSettings();
        Opportunity acme = OpenBoxTestData.opportunityNamed(ACME_NAME);
        OpenBox_Governed_Request__c pending = pendingRequest(acme, 25);
        OpenBoxCoreMock core = OpenBoxCoreMock.install().answerApproval('require_approval', null);

        Test.startTest();
        OpenBoxDiscountGovernance.Outcome outcome = new OpenBoxDiscountGovernance()
            .resolvePending(new Set<Id>{ pending.Id })[0];
        Test.stopTest();

        Assert.areEqual(OpenBoxDiscountGovernance.STATUS_PENDING, outcome.status);
        assertDiscount(ACME_NAME, 5);
        Assert.areEqual(0, core.evaluated.size(), 'polling a pending approval emits no governance events');
        OpenBox_Governed_Request__c record = [
            SELECT Poll_Count__c, Last_Polled_At__c
            FROM OpenBox_Governed_Request__c
            WHERE Id = :pending.Id
        ];
        Assert.isTrue(record.Poll_Count__c == 1, 'exactly one poll, and the resolver must not re-trigger the poller');
        Assert.isNotNull(record.Last_Polled_At__c);
    }

    // ── Concurrent edit ─────────────────────────────────────────────────────────────────────

    @IsTest
    static void recordEditedWhileAwaitingApprovalIsRejectedAsStale() {
        OpenBoxTestData.useDefaultSettings();
        Opportunity acme = OpenBoxTestData.opportunityNamed(ACME_NAME);
        OpenBox_Governed_Request__c pending = pendingRequest(acme, 25);
        System.runAs(OpenBoxTestData.adminUser()) {
            update new Opportunity(
                Id = acme.Id,
                Discount__c = 7,
                Description = 'Re-priced by a human while approval was pending'
            );
        }
        OpenBoxCoreMock core = OpenBoxCoreMock.install().answerApproval('allow', 'Approved');

        Test.startTest();
        System.enqueueJob(new OpenBoxApprovalPoller());
        Test.stopTest();

        OpenBox_Governed_Request__c record = [
            SELECT Status__c, Reason__c
            FROM OpenBox_Governed_Request__c
            WHERE Id = :pending.Id
        ];
        Assert.areEqual(OpenBoxDiscountGovernance.STATUS_STALE, record.Status__c, record.Reason__c);
        assertDiscount(ACME_NAME, 7, 'a stale approval must not overwrite the human edit');
        Assert.areEqual(0, countSpans(core, 'UPDATE Opportunity'), 'no write is attempted for a stale record');
        Assert.areEqual(
            'StaleRecord',
            ((Map<String, Object>) completionOf(core, OpenBoxDiscountGovernance.ACTIVITY_UPDATE).get('error'))
                .get('type')
        );
    }

    // ── OpenBox unavailable, timeout, malformed ─────────────────────────────────────────────

    @IsTest
    static void unavailableOpenBoxFailsClosed() {
        OpenBoxCoreMock core = OpenBoxCoreMock.install().failNext(10, 503);
        assertFailsClosed(core);
        Assert.areEqual(2, core.requests.size(), 'gateway errors are retried exactly once, then fail closed');
    }

    @IsTest
    static void timeoutFailsClosed() {
        assertFailsClosed(OpenBoxCoreMock.install().throwCalloutExceptions());
    }

    @IsTest
    static void malformedResponseFailsClosed() {
        assertFailsClosed(OpenBoxCoreMock.install().answerRaw('<html>gateway</html>'));
    }

    @IsTest
    static void unknownVerdictFailsClosed() {
        assertFailsClosed(OpenBoxCoreMock.install().answerRaw('{"verdict":"constrain","action":"constrain"}'));
    }

    @IsTest
    static void serverErrorIsNotRetriedAndFailsClosed() {
        OpenBoxCoreMock core = OpenBoxCoreMock.install().failNext(10, 500);
        assertFailsClosed(core);
        Assert.areEqual(1, core.requests.size(), 'a 500 may already be recorded by Core and is never retried');
    }

    // ── Salesforce permission checks ────────────────────────────────────────────────────────

    @IsTest
    static void salesforcePermissionFailureBlocksWriteEvenWhenOpenBoxAllows() {
        OpenBoxTestData.useDefaultSettings();
        OpenBoxCoreMock core = OpenBoxCoreMock.install();
        Opportunity globex = OpenBoxTestData.opportunityNamed(GLOBEX_NAME);
        OpenBoxDiscountGovernance.Outcome outcome;

        System.runAs(OpenBoxTestData.readOnlyUser()) {
            Test.startTest();
            outcome = governOne(globex.Id, 10);
            Test.stopTest();
        }

        Assert.areEqual('ALLOW', outcome.decision, 'OpenBox allowed the change');
        Assert.areEqual(OpenBoxDiscountGovernance.STATUS_PERMISSION_DENIED, outcome.status, outcome.message);
        assertDiscount(GLOBEX_NAME, 5, 'Salesforce access must still be enforced');
        Assert.areEqual(new List<String>{ 'Allowed', 'Permission_Denied' }, OpenBoxTestData.auditOutcomes());
        Assert.areEqual(
            'PermissionDenied',
            ((Map<String, Object>) completionOf(core, OpenBoxDiscountGovernance.ACTIVITY_UPDATE).get('error'))
                .get('type')
        );
        assertFullyPaired(core);
    }

    @IsTest
    static void userWithoutGovernedPermissionIsRefusedBeforeContactingOpenBox() {
        OpenBoxTestData.useDefaultSettings();
        OpenBoxCoreMock core = OpenBoxCoreMock.install();
        Opportunity acme = OpenBoxTestData.opportunityNamed(ACME_NAME);
        OpenBoxDiscountGovernance.Outcome outcome;

        System.runAs(OpenBoxTestData.outsiderUser()) {
            Test.startTest();
            outcome = governOne(acme.Id, 10);
            Test.stopTest();
        }

        Assert.areEqual(OpenBoxDiscountGovernance.STATUS_PERMISSION_DENIED, outcome.status);
        Assert.areEqual(0, core.requests.size(), 'no governance session is opened for an unentitled caller');
        assertDiscount(ACME_NAME, 5);
    }

    // ── Behaviour rules (span-level verdicts) ───────────────────────────────────────────────

    @IsTest
    static void behaviourRuleBlockOnWriteSpanPreventsWrite() {
        OpenBoxTestData.useDefaultSettings();
        OpenBoxCoreMock core = OpenBoxCoreMock.install()
            .onSpanStarted('UPDATE', 'block', 'Behavioral violation: discount writes require a locked read');
        Opportunity acme = OpenBoxTestData.opportunityNamed(ACME_NAME);
        OpenBoxDiscountGovernance.Outcome outcome;

        System.runAs(OpenBoxTestData.agentUser()) {
            Test.startTest();
            outcome = governOne(acme.Id, 10);
            Test.stopTest();
        }

        Assert.areEqual(OpenBoxDiscountGovernance.STATUS_BLOCKED, outcome.status);
        assertDiscount(ACME_NAME, 5);
        Assert.areEqual(2, countSpans(core, 'UPDATE Opportunity'), 'the refused write span is still closed');
        Map<String, Object> closed = lastSpan(core, 'UPDATE Opportunity');
        Assert.areEqual('completed', closed.get('stage'));
        Assert.areEqual('ERROR', ((Map<String, Object>) closed.get('status')).get('code'));
        Assert.isNull(closed.get('rowcount'), 'a refused write touched no rows');
        Assert.areEqual('failed', completionOf(core, OpenBoxDiscountGovernance.ACTIVITY_UPDATE).get('status'));
        assertFullyPaired(core);
    }

    @IsTest
    static void behaviourRuleApprovalOnWriteSpanPendsRequest() {
        OpenBoxTestData.useDefaultSettings();
        OpenBoxCoreMock core = OpenBoxCoreMock.install()
            .onSpanStarted('UPDATE', 'require_approval', 'Behavioral violation: sales-ops sign-off missing');
        Opportunity acme = OpenBoxTestData.opportunityNamed(ACME_NAME);
        OpenBoxDiscountGovernance.Outcome outcome;

        System.runAs(OpenBoxTestData.agentUser()) {
            Test.startTest();
            outcome = governOne(acme.Id, 10);
            Test.stopTest();
        }

        Assert.areEqual(OpenBoxDiscountGovernance.STATUS_PENDING, outcome.status);
        Assert.areEqual('REQUIRE_APPROVAL', outcome.decision);
        assertDiscount(ACME_NAME, 5);
        assertSpansPaired(core);
        Assert.areEqual(0, core.eventsOfType('WorkflowCompleted').size(), 'the run waits for the approver');
    }

    // ── Guardrails ──────────────────────────────────────────────────────────────────────────

    @IsTest
    static void guardrailRedactionIsWhatSalesforceStores() {
        OpenBoxTestData.useDefaultSettings();
        Map<String, Object> redacted = new Map<String, Object>{
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
        };
        OpenBoxCoreMock.install().onActivityStarted(OpenBoxDiscountGovernance.ACTIVITY_UPDATE, redacted);
        Opportunity acme = OpenBoxTestData.opportunityNamed(ACME_NAME);

        System.runAs(OpenBoxTestData.agentUser()) {
            Test.startTest();
            new OpenBoxDiscountGovernance()
                .requestDiscounts(
                    new List<OpenBoxDiscountGovernance.DiscountRequest>{
                        OpenBoxTestData.request(acme.Id, 10, 'Call jane.doe@example.com to confirm')
                    }
                );
            Test.stopTest();
        }

        Assert.areEqual('Call <EMAIL_ADDRESS> to confirm', OpenBoxTestData.governedRequests()[0].Justification__c);
    }

    @IsTest
    static void outputGuardrailRedactsWhatTheAgentIsTold() {
        OpenBoxTestData.useDefaultSettings();
        Map<String, Object> redacted = new Map<String, Object>{
            'verdict' => 'allow',
            'action' => 'allow',
            'guardrails_result' => new Map<String, Object>{
                'validation_passed' => true,
                'input_type' => 'activity_output',
                'redacted_input' => new Map<String, Object>{
                    'description' => 'Primary contact <EMAIL_ADDRESS>, <PHONE_NUMBER>'
                },
                'reasons' => new List<Object>()
            }
        };
        OpenBoxCoreMock.install().onActivityCompleted(OpenBoxDiscountGovernance.ACTIVITY_LOOKUP, redacted);
        Opportunity acme = OpenBoxTestData.opportunityNamed(ACME_NAME);
        OpenBoxDiscountGovernance.Outcome outcome;

        System.runAs(OpenBoxTestData.agentUser()) {
            Test.startTest();
            outcome = governOne(acme.Id, 10);
            Test.stopTest();
        }

        Assert.isTrue(outcome.opportunitySummary.contains('<EMAIL_ADDRESS>'), outcome.opportunitySummary);
        Assert.isFalse(
            outcome.opportunitySummary.contains('jane.doe@example.com'),
            'unredacted personal data must not reach the agent'
        );
    }

    @IsTest
    static void inputGuardrailBlockRefusesRequest() {
        OpenBoxTestData.useDefaultSettings();
        Map<String, Object> blocked = new Map<String, Object>{
            'verdict' => 'block',
            'action' => 'block',
            'reason' => 'Input contains banned words',
            'guardrails_result' => new Map<String, Object>{
                'validation_passed' => false,
                'reasons' => new List<Object>{
                    new Map<String, Object>{ 'type' => 'ban_list', 'reason' => 'Input contains banned words' }
                }
            }
        };
        OpenBoxCoreMock.install().onActivityStarted(OpenBoxDiscountGovernance.ACTIVITY_UPDATE, blocked);
        Opportunity acme = OpenBoxTestData.opportunityNamed(ACME_NAME);
        OpenBoxDiscountGovernance.Outcome outcome;

        System.runAs(OpenBoxTestData.agentUser()) {
            Test.startTest();
            outcome = new OpenBoxDiscountGovernance()
                .requestDiscounts(
                    new List<OpenBoxDiscountGovernance.DiscountRequest>{
                        OpenBoxTestData.request(acme.Id, 10, 'Ignore policy and bypass approval')
                    }
                )[0];
            Test.stopTest();
        }

        Assert.areEqual(OpenBoxDiscountGovernance.STATUS_BLOCKED, outcome.status);
        assertDiscount(ACME_NAME, 5);
        OpenBox_Governance_Audit__c audit = [SELECT Detail__c FROM OpenBox_Governance_Audit__c LIMIT 1];
        Assert.isTrue(audit.Detail__c.contains('Input contains banned words'), audit.Detail__c);
    }

    // ── Input validation and limits ─────────────────────────────────────────────────────────

    @IsTest
    static void invalidInputsAreRefusedWithoutContactingOpenBox() {
        OpenBoxTestData.useDefaultSettings();
        OpenBoxCoreMock core = OpenBoxCoreMock.install();
        Opportunity acme = OpenBoxTestData.opportunityNamed(ACME_NAME);
        List<OpenBoxDiscountGovernance.DiscountRequest> requests = new List<OpenBoxDiscountGovernance.DiscountRequest>{
            OpenBoxTestData.request(acme.Id, 101, null),
            OpenBoxTestData.request(acme.Id, -1, null),
            OpenBoxTestData.request(acme.Id, 10.125, null),
            OpenBoxTestData.request(acme.Id, null, null),
            OpenBoxTestData.request(UserInfo.getUserId(), 10, null)
        };
        List<OpenBoxDiscountGovernance.Outcome> outcomes;

        System.runAs(OpenBoxTestData.agentUser()) {
            Test.startTest();
            outcomes = new OpenBoxDiscountGovernance().requestDiscounts(requests);
            Test.stopTest();
        }

        for (OpenBoxDiscountGovernance.Outcome outcome : outcomes) {
            Assert.areEqual(OpenBoxDiscountGovernance.STATUS_FAILED, outcome.status, outcome.message);
            Assert.isFalse(outcome.changed);
        }
        Assert.areEqual(0, core.requests.size());
        Assert.areEqual(5, [SELECT COUNT() FROM OpenBox_Governance_Audit__c WHERE Outcome__c = 'Invalid_Request']);
    }

    @IsTest
    static void requestsBeyondPerTransactionLimitAreRefused() {
        OpenBoxTestData.useDefaultSettings();
        OpenBoxCoreMock.install();
        Opportunity acme = OpenBoxTestData.opportunityNamed(ACME_NAME);
        List<OpenBoxDiscountGovernance.DiscountRequest> requests = new List<OpenBoxDiscountGovernance.DiscountRequest>();
        for (Integer i = 0; i < 6; i++) {
            requests.add(OpenBoxTestData.request(acme.Id, 6 + i, null));
        }
        List<OpenBoxDiscountGovernance.Outcome> outcomes;

        System.runAs(OpenBoxTestData.agentUser()) {
            Test.startTest();
            outcomes = new OpenBoxDiscountGovernance().requestDiscounts(requests);
            Test.stopTest();
        }

        Assert.areEqual(6, outcomes.size());
        Assert.areEqual(OpenBoxDiscountGovernance.STATUS_FAILED, outcomes[5].status);
        Assert.isTrue(outcomes[5].reason.contains('At most 5'), outcomes[5].reason);
    }

    // ── Helpers ─────────────────────────────────────────────────────────────────────────────

    private static void assertDiscount(String opportunityName, Decimal expected) {
        assertDiscount(opportunityName, expected, 'unexpected discount on ' + opportunityName);
    }

    private static void assertDiscount(String opportunityName, Decimal expected, String message) {
        Decimal actual = OpenBoxTestData.opportunityNamed(opportunityName).Discount__c;
        Assert.isTrue(actual == expected, message + ' (expected ' + expected + ', found ' + actual + ')');
    }

    private static OpenBoxDiscountGovernance.Outcome governOne(Id opportunityId, Decimal discount) {
        return new OpenBoxDiscountGovernance()
            .requestDiscounts(
                new List<OpenBoxDiscountGovernance.DiscountRequest>{
                    OpenBoxTestData.request(opportunityId, discount, 'Strategic account')
                }
            )[0];
    }

    private static void assertFailsClosed(OpenBoxCoreMock core) {
        OpenBoxTestData.useDefaultSettings();
        Opportunity acme = OpenBoxTestData.opportunityNamed(ACME_NAME);
        OpenBoxDiscountGovernance.Outcome outcome;

        System.runAs(OpenBoxTestData.agentUser()) {
            Test.startTest();
            outcome = governOne(acme.Id, 10);
            core.healthy();
            Test.stopTest();
        }

        Assert.areEqual(OpenBoxDiscountGovernance.STATUS_FAILED, outcome.status, outcome.message);
        Assert.areEqual('ERROR', outcome.decision);
        Assert.isFalse(outcome.changed);
        assertDiscount(ACME_NAME, 5, 'no decision means no write');
        Assert.areEqual(new List<String>{ 'Governance_Unavailable' }, OpenBoxTestData.auditOutcomes());
        Assert.isNotNull(OpenBoxTestData.governedRequests()[0].Error__c);
    }

    private static void assertApprovalTerminal(
        String action,
        String reason,
        String expectedStatus,
        String expectedErrorType
    ) {
        OpenBoxTestData.useDefaultSettings();
        Opportunity acme = OpenBoxTestData.opportunityNamed(ACME_NAME);
        OpenBox_Governed_Request__c pending = pendingRequest(acme, 25);
        OpenBoxCoreMock core = OpenBoxCoreMock.install().answerApproval(action, reason);

        Test.startTest();
        OpenBoxDiscountGovernance.Outcome outcome = new OpenBoxDiscountGovernance()
            .resolvePending(new Set<Id>{ pending.Id })[0];
        Test.stopTest();

        Assert.areEqual(expectedStatus, outcome.status);
        Assert.isFalse(outcome.changed);
        assertDiscount(ACME_NAME, 5, 'a rejected or expired approval must not write');
        Map<String, Object> completion = completionOf(core, OpenBoxDiscountGovernance.ACTIVITY_UPDATE);
        Assert.areEqual(pending.Activity_Id__c, completion.get('activity_id'));
        Assert.areEqual(expectedErrorType, ((Map<String, Object>) completion.get('error')).get('type'));
        Assert.areEqual('failed', core.eventsOfType('WorkflowCompleted')[0].get('status'));
    }

    /**
     * A request as the authorizing transaction would have left it: decided REQUIRE_APPROVAL, with
     * the run's correlation ids recorded and nothing written.
     */
    private static OpenBox_Governed_Request__c pendingRequest(Opportunity opportunity, Decimal discount) {
        String requestId = UUID.randomUUID().toString();
        OpenBox_Governed_Request__c record = new OpenBox_Governed_Request__c(
            Request_Id__c = requestId,
            Opportunity__c = opportunity.Id,
            Action__c = OpenBoxDiscountGovernance.ACTION,
            Requested_Discount__c = discount,
            Previous_Discount__c = opportunity.Discount__c,
            Baseline_Modstamp__c = opportunity.SystemModstamp,
            Status__c = OpenBoxDiscountGovernance.STATUS_PENDING,
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

    private static Map<String, Object> completionOf(OpenBoxCoreMock core, String activityType) {
        for (Map<String, Object> event : core.eventsOfType('ActivityCompleted')) {
            if (event.get('activity_type') == activityType) {
                return event;
            }
        }
        Assert.fail('no ActivityCompleted for ' + activityType + ' in ' + core.eventSequence());
        return null;
    }

    private static Map<String, Object> lastSpan(OpenBoxCoreMock core, String name) {
        Map<String, Object> found;
        for (Map<String, Object> span : core.spans()) {
            if (span.get('name') == name) {
                found = span;
            }
        }
        return found;
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

    /**
     * The OpenBox pairing invariants for a run that has ended.
     */
    private static void assertFullyPaired(OpenBoxCoreMock core) {
        Assert.areEqual(1, core.eventsOfType('WorkflowStarted').size(), 'exactly one WorkflowStarted');
        Assert.areEqual(
            1,
            core.eventsOfType('WorkflowCompleted').size() + core.eventsOfType('WorkflowFailed').size(),
            'exactly one terminal workflow event'
        );

        Map<String, Integer> openActivities = new Map<String, Integer>();
        for (Map<String, Object> started : core.eventsOfType('ActivityStarted')) {
            openActivities.put((String) started.get('activity_id'), 1);
        }
        for (Map<String, Object> completed : core.eventsOfType('ActivityCompleted')) {
            String activityId = (String) completed.get('activity_id');
            Assert.isTrue(
                openActivities.containsKey(activityId),
                'ActivityCompleted without a matching ActivityStarted: ' + activityId
            );
            openActivities.put(activityId, openActivities.get(activityId) - 1);
        }
        for (String activityId : openActivities.keySet()) {
            Assert.areEqual(0, openActivities.get(activityId), 'activity not closed exactly once: ' + activityId);
        }
        assertSpansPaired(core);

        String workflowId = (String) core.evaluated[0].get('workflow_id');
        String runId = (String) core.evaluated[0].get('run_id');
        for (Map<String, Object> event : core.evaluated) {
            Assert.areEqual(workflowId, event.get('workflow_id'), 'workflow_id must be stable across a run');
            Assert.areEqual(runId, event.get('run_id'), 'run_id must be stable across a run');
        }
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
            Assert.areEqual(
                new List<String>{ 'started', 'completed' },
                stagesBySpan.get(spanId),
                'span ' + spanId + ' must be reported started then completed'
            );
        }
    }
}
