/**
 * Pins the OpenBox wire contract: span and event shapes, identifier formats, and the parsing of
 * evaluate and approval responses. A change that drifts from the contract the OpenBox SDKs use
 * fails here before it can reach Core.
 */
@IsTest
private class OpenBoxWireContractTest {
    private static final Set<String> COMMON_SPAN_FIELDS = new Set<String>{
        'span_id',
        'trace_id',
        'parent_span_id',
        'name',
        'kind',
        'stage',
        'start_time',
        'end_time',
        'duration_ns',
        'attributes',
        'status',
        'events',
        'hook_type',
        'error'
    };
    private static final Set<String> DB_FAMILY_FIELDS = new Set<String>{
        'db_system',
        'db_name',
        'db_operation',
        'db_statement',
        'server_address',
        'server_port',
        'rowcount'
    };

    private static OpenBoxEvents.Identity identity() {
        return new OpenBoxEvents.Identity(
            'wf-1',
            'run-1',
            'AgentforceGovernedAction',
            'salesforce-agentforce',
            'Agent',
            'session-1'
        );
    }

    @IsTest
    static void identifiersFollowOtelHexWidths() {
        Pattern spanId = Pattern.compile('^[0-9a-f]{16}$');
        Pattern traceId = Pattern.compile('^[0-9a-f]{32}$');
        for (Integer i = 0; i < 20; i++) {
            Assert.isTrue(spanId.matcher(OpenBoxIds.newSpanId()).matches());
            Assert.isTrue(traceId.matcher(OpenBoxIds.newTraceId()).matches());
        }
        Assert.isTrue(Pattern.matches('^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d{3}Z$', OpenBoxIds.timestamp()));
        Datetime now = Datetime.now();
        Assert.areEqual(now.getTime() * 1000000L, OpenBoxIds.toNanos(now), 'span times are epoch nanoseconds');
    }

    @IsTest
    static void startedSpanCarriesFullFlatContractWithExplicitNulls() {
        OpenBoxSpan span = OpenBoxSpan.dmlUpdate(
            OpenBoxIds.newTraceId(),
            null,
            'Opportunity',
            'UPDATE Opportunity SET Discount__c = 10 WHERE Id = \'006000000000001\'',
            new Map<String, Object>{ 'salesforce.field' => 'Discount__c' }
        );
        Map<String, Object> wire = span.toStartedWire();

        Assert.isTrue(wire.keySet().containsAll(COMMON_SPAN_FIELDS), 'missing common fields: ' + wire.keySet());
        Assert.isTrue(wire.keySet().containsAll(DB_FAMILY_FIELDS), 'missing db family fields: ' + wire.keySet());
        Assert.areEqual('started', wire.get('stage'));
        Assert.areEqual(
            'UPDATE Opportunity',
            wire.get('name'),
            'Core derives database_update from the SQL verb in the name'
        );
        Assert.areEqual('db_query', wire.get('hook_type'));
        Assert.isTrue(
            wire.containsKey('end_time') && wire.get('end_time') == null,
            'started spans send end_time: null'
        );
        Assert.isTrue(
            wire.containsKey('duration_ns') && wire.get('duration_ns') == null,
            'started spans send duration_ns: null'
        );
        Assert.isFalse(wire.containsKey('semantic_type'), 'semantic_type is computed by Core, never sent');
        Assert.isInstanceOfType(wire.get('start_time'), Long.class, 'times must serialise as JSON integers');

        Map<String, Object> attributes = (Map<String, Object>) wire.get('attributes');
        Assert.areEqual('salesforce', attributes.get('db.system'), 'db.system gates database classification');
        Assert.areEqual('UPDATE', attributes.get('db.operation'));
        Assert.isNotNull(attributes.get('db.statement'), 'Core rebuilds the approval fingerprint from attributes');
        Assert.areEqual('Discount__c', attributes.get('salesforce.field'));
        Assert.areEqual('UNSET', ((Map<String, Object>) wire.get('status')).get('code'));
    }

    @IsTest
    static void completedSpanSharesIdentityAndReportsOutcome() {
        OpenBoxSpan span = OpenBoxSpan.soqlSelect(
            OpenBoxIds.newTraceId(),
            null,
            'Opportunity',
            'SELECT Id FROM Opportunity',
            null
        );
        Map<String, Object> started = span.toStartedWire();
        Map<String, Object> completed = span.succeeded(1).toCompletedWire();

        Assert.areEqual(started.get('span_id'), completed.get('span_id'), 'both stages share one span_id');
        Assert.areEqual(started.get('trace_id'), completed.get('trace_id'));
        Assert.areEqual(started.get('start_time'), completed.get('start_time'));
        Assert.areEqual('completed', completed.get('stage'));
        Assert.areEqual(1, completed.get('rowcount'));
        Long duration = (Long) completed.get('duration_ns');
        Assert.isTrue(duration >= 1000000L, 'duration is at least one clock tick');
        Assert.areEqual((Long) completed.get('start_time') + duration, completed.get('end_time'));
        Assert.areEqual('OK', ((Map<String, Object>) completed.get('status')).get('code'));
        Assert.isNull(completed.get('error'));
    }

    @IsTest
    static void failedSpanReportsErrorStatus() {
        OpenBoxSpan span = OpenBoxSpan.dmlUpdate(
            OpenBoxIds.newTraceId(),
            null,
            'Opportunity',
            'UPDATE Opportunity',
            null
        );
        Map<String, Object> completed = span.failed('DmlException', 'FIELD_CUSTOM_VALIDATION_EXCEPTION')
            .toCompletedWire();
        Map<String, Object> status = (Map<String, Object>) completed.get('status');
        Assert.areEqual('ERROR', status.get('code'), 'Core marks a span as errored only from status.code');
        Assert.isTrue(String.valueOf(completed.get('error')).contains('DmlException'));
        Assert.isNull(completed.get('rowcount'));
    }

    @IsTest
    static void unfinishedSpanCannotBeReportedCompleted() {
        OpenBoxSpan span = OpenBoxSpan.soqlSelect(
            OpenBoxIds.newTraceId(),
            null,
            'Opportunity',
            'SELECT Id FROM Opportunity',
            null
        );
        try {
            span.toCompletedWire();
            Assert.fail('a span must finish before it is reported completed');
        } catch (OpenBoxContractException e) {
            Assert.isTrue(e.getMessage().contains('has not finished'));
        }
    }

    @IsTest
    static void lifecycleEventsFollowLangGraphWireShape() {
        OpenBoxEvents.Identity id = identity();

        Map<String, Object> started = OpenBoxEvents.workflowStarted(
            id,
            new Map<String, Object>{ 'a' => 1 },
            'the goal'
        );
        Assert.areEqual('WorkflowStarted', started.get('event_type'));
        Assert.areEqual('run-1-wf', started.get('activity_id'));
        Assert.areEqual('workflow-telemetry', started.get('source'));
        Assert.areEqual(false, started.get('hook_trigger'));
        Assert.areEqual('salesforce-agentforce', started.get('task_queue'));
        Assert.areEqual('session-1', started.get('session_id'));
        Assert.areEqual('the goal', started.get('goal'));
        Assert.isInstanceOfType(started.get('activity_input'), List<Object>.class, 'activity_input is always an array');

        Map<String, Object> signal = OpenBoxEvents.signalReceived(id, 'user_prompt', new List<Object>{ 'hi' });
        Assert.areEqual('run-1-sig', signal.get('activity_id'));
        Assert.areEqual('user_prompt', signal.get('signal_name'));

        Map<String, Object> activityStarted = OpenBoxEvents.activityStarted(
            id,
            'act-1',
            'OpportunityDiscountUpdate',
            new Map<String, Object>()
        );
        Map<String, Object> activityCompleted = OpenBoxEvents.activityCompleted(
            id,
            'act-1',
            'OpportunityDiscountUpdate',
            'failed',
            null,
            OpenBoxEvents.error('GovernanceBlocked', 'no'),
            5
        );
        Assert.areEqual(
            activityStarted.get('activity_id'),
            activityCompleted.get('activity_id'),
            'a pair shares its activity_id'
        );
        Assert.areEqual(
            new Map<String, Object>{ 'type' => 'GovernanceBlocked', 'message' => 'no' },
            activityCompleted.get('error'),
            'errors are {type, message} objects'
        );

        Map<String, Object> completed = OpenBoxEvents.workflowCompleted(
            id,
            'completed',
            new Map<String, Object>(),
            null,
            10
        );
        Assert.areEqual(
            started.get('activity_id'),
            completed.get('activity_id'),
            'workflow boundary events share run_id-wf'
        );
        Assert.areEqual(completed.get('activity_output'), completed.get('workflow_output'));

        Map<String, Object> failed = OpenBoxEvents.workflowFailed(
            id,
            'terminated',
            OpenBoxEvents.error('halt', 'halted')
        );
        Assert.areEqual('WorkflowFailed', failed.get('event_type'));
        Assert.areEqual('terminated', failed.get('status'));
    }

    @IsTest
    static void hookEventIsActivityStartedWithOneSpan() {
        OpenBoxSpan span = OpenBoxSpan.soqlSelect(
            OpenBoxIds.newTraceId(),
            null,
            'Opportunity',
            'SELECT Id FROM Opportunity',
            null
        );
        Map<String, Object> hook = OpenBoxEvents.hook(identity(), 'act-1', 'OpportunityLookup', span.toStartedWire());
        Assert.areEqual('ActivityStarted', hook.get('event_type'), 'hooks are wire ActivityStarted');
        Assert.areEqual(true, hook.get('hook_trigger'));
        Assert.areEqual(
            1,
            ((List<Object>) hook.get('spans')).size(),
            'Core stores only the last span; one per hook event'
        );
        Assert.areEqual(1, hook.get('span_count'));
        Assert.areEqual('act-1', hook.get('activity_id'));
    }

    @IsTest
    static void identityRequiresCorrelationIds() {
        try {
            new OpenBoxEvents.Identity('', 'run', 'type', null, null, null);
            Assert.fail('workflow_id is mandatory');
        } catch (OpenBoxContractException e) {
            Assert.isTrue(e.getMessage().contains('required'));
        }
    }

    @IsTest
    static void evaluationResultParsesLiveResponseShape() {
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(
            '{"governance_event_id":"e1","verdict":"require_approval","action":"require_approval","risk_score":0.4,' +
                '"trust_tier":2,"reason":"over threshold","policy_id":"p1","approval_expiration_time":"2026-10-12T10:00:00Z",' +
                '"fallback_used":false,"guardrails_result":{"validation_passed":false,"input_type":"activity_input",' +
                '"redacted_input":[{"justification":"<EMAIL_ADDRESS>"}],"reasons":[{"type":"pii","field":"input.0.justification","reason":"PII found"}]},' +
                '"age_result":{"goal_drifted":true},"behavioral_violations":[{"rule_id":"r1"}]}'
        );
        OpenBoxEvaluationResult result = new OpenBoxEvaluationResult(body);
        Assert.areEqual(OpenBoxVerdict.REQUIRE_APPROVAL, result.verdict);
        Assert.areEqual('e1', result.governanceEventId);
        Assert.areEqual('p1', result.policyId);
        Assert.areEqual(2, result.trustTier);
        Assert.areEqual(Datetime.newInstanceGmt(2026, 10, 12, 10, 0, 0), result.approvalExpiresAt);
        Assert.isFalse(result.guardrailsPassed);
        Assert.areEqual(new List<String>{ 'PII found' }, result.guardrailReasons);
        Assert.areEqual('<EMAIL_ADDRESS>', result.redactedInputField('justification'));
        Assert.isTrue(result.goalDrifted);
        Assert.isTrue(result.behavioralViolation);
        Assert.isFalse(result.isAllowed());
    }

    @IsTest
    static void legacyActionFieldIsHonouredAndCaseIgnored() {
        OpenBoxEvaluationResult result = new OpenBoxEvaluationResult(new Map<String, Object>{ 'action' => 'ALLOW' });
        Assert.isTrue(result.isAllowed());
    }

    @IsTest
    static void unknownOrMissingVerdictsAreContractViolations() {
        for (
            Map<String, Object> body : new List<Map<String, Object>>{
                new Map<String, Object>(),
                new Map<String, Object>{ 'verdict' => 'constrain' },
                new Map<String, Object>{ 'verdict' => 'deny' }
            }
        ) {
            try {
                new OpenBoxEvaluationResult(body);
                Assert.fail('must reject ' + body);
            } catch (OpenBoxContractException e) {
                Assert.isNotNull(e.getMessage());
            }
        }
    }

    @IsTest
    static void approvalStatesMapFromCoreActions() {
        Datetime now = Datetime.now();
        String future = OpenBoxIds.timestamp(now.addMinutes(5));
        String past = OpenBoxIds.timestamp(now.addMinutes(-5));
        Map<String, OpenBoxApprovalResult.State> expectations = new Map<String, OpenBoxApprovalResult.State>{
            '{"action":"allow"}' => OpenBoxApprovalResult.State.APPROVED,
            '{"action":"require_approval","approval_expiration_time":"' +
            future +
            '"}' => OpenBoxApprovalResult.State.PENDING,
            '{"action":"require_approval","approval_expiration_time":"' +
            past +
            '"}' => OpenBoxApprovalResult.State.EXPIRED,
            '{"action":"halt","reason":"Rejected by approver"}' => OpenBoxApprovalResult.State.REJECTED,
            '{"action":"halt","reason":"approval request expired"}' => OpenBoxApprovalResult.State.EXPIRED,
            '{"action":"block","patch":{"new_input":{}}}' => OpenBoxApprovalResult.State.REJECTED
        };
        for (String body : expectations.keySet()) {
            OpenBoxApprovalResult result = new OpenBoxApprovalResult(
                (Map<String, Object>) JSON.deserializeUntyped(body),
                now
            );
            Assert.areEqual(expectations.get(body), result.status, body);
            Assert.areEqual(expectations.get(body) != OpenBoxApprovalResult.State.PENDING, result.isTerminal());
        }
    }

    @IsTest
    static void approvalWithoutActionIsContractViolation() {
        try {
            new OpenBoxApprovalResult(new Map<String, Object>{ 'id' => 'x' }, Datetime.now());
            Assert.fail('an approval answer must carry an action');
        } catch (OpenBoxContractException e) {
            Assert.isTrue(e.getMessage().contains('no action'));
        }
    }

    @IsTest
    static void unparseableTimestampIsContractViolation() {
        try {
            OpenBoxIds.parseTimestamp('yesterday');
            Assert.fail('timestamps must be RFC 3339');
        } catch (OpenBoxContractException e) {
            Assert.isTrue(e.getMessage().contains('yesterday'));
        }
    }
}
