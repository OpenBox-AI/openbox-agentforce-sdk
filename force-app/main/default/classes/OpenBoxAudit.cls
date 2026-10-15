/**
 * Builds append-only audit entries correlating an OpenBox decision with the Salesforce outcome.
 * Entries are collected during the decision phase and inserted with the rest of the transaction's
 * writes, so an audit row is never committed for work that was rolled back.
 *
 * Details are structured JSON. They carry ids, decisions and reasons only: never credentials,
 * never request headers, and free text only after OpenBox guardrail redaction.
 */
public inherited sharing class OpenBoxAudit {
    public static final String STAGE_PROMPT = 'Prompt';
    public static final String STAGE_AUTHORIZATION = 'Authorization';
    public static final String STAGE_APPROVAL = 'Approval';
    public static final String STAGE_EXECUTION = 'Execution';
    public static final String STAGE_TELEMETRY = 'Telemetry';

    private static final Integer MAX_DETAIL_CHARS = 32000;

    private OpenBoxAudit() {
    }

    public static OpenBox_Governance_Audit__c entry(
        String requestId,
        String stage,
        String outcome,
        OpenBoxEvaluationResult decision,
        Id opportunityId,
        Id actorId,
        Map<String, Object> detail
    ) {
        Map<String, Object> payload = detail == null ? new Map<String, Object>() : detail.clone();
        if (decision != null) {
            payload.put('verdict', decision.verdict.name());
            payload.put('reason', decision.reason);
            payload.put('policy_id', decision.policyId);
            payload.put('risk_score', decision.riskScore);
            payload.put('trust_tier', decision.trustTier);
            payload.put('guardrails_passed', decision.guardrailsPassed);
            payload.put('guardrail_reasons', decision.guardrailReasons);
            payload.put('behavioral_violation', decision.behavioralViolation);
        }
        return new OpenBox_Governance_Audit__c(
            Request_Id__c = requestId,
            Stage__c = stage,
            Outcome__c = outcome,
            Decision__c = decision == null ? null : decision.verdict.name(),
            Decision_Id__c = decision == null ? null : decision.governanceEventId,
            Opportunity_Id__c = opportunityId,
            Action__c = OpenBoxDiscountGovernance.ACTION,
            Actor__c = actorId,
            Occurred_At__c = Datetime.now(),
            Detail__c = JSON.serializePretty(payload).abbreviate(MAX_DETAIL_CHARS)
        );
    }

    /**
     * Links each entry to its governed request once the request rows have ids.
     */
    public static void link(List<OpenBox_Governance_Audit__c> entries, Map<String, Id> requestIdsByRequestKey) {
        for (OpenBox_Governance_Audit__c entry : entries) {
            if (entry.Governed_Request__c == null && requestIdsByRequestKey.containsKey(entry.Request_Id__c)) {
                entry.Governed_Request__c = requestIdsByRequestKey.get(entry.Request_Id__c);
            }
        }
    }
}
