/**
 * Typed view of an OpenBox Core evaluate response. Construction validates the response: a missing
 * or unrecognised verdict raises OpenBoxContractException rather than defaulting to anything.
 */
public inherited sharing class OpenBoxEvaluationResult {
    public final OpenBoxVerdict verdict;
    public final String reason;
    public final String governanceEventId;
    public final String policyId;
    public final Decimal riskScore;
    public final Integer trustTier;
    public final Datetime approvalExpiresAt;
    public final Boolean guardrailsPassed;
    public final List<String> guardrailReasons;
    public final Boolean behavioralViolation;
    public final Boolean goalDrifted;
    public final Map<String, Object> raw;

    private final Object redactedInput;

    public OpenBoxEvaluationResult(Map<String, Object> body) {
        if (body == null) {
            throw new OpenBoxContractException('OpenBox returned an empty evaluation body');
        }
        this.raw = body;
        this.verdict = parseVerdict(firstNonBlank(asString(body.get('verdict')), asString(body.get('action'))));
        this.reason = asString(body.get('reason'));
        this.governanceEventId = asString(body.get('governance_event_id'));
        this.policyId = asString(body.get('policy_id'));
        this.riskScore = body.get('risk_score') == null
            ? null
            : Decimal.valueOf(String.valueOf(body.get('risk_score')));
        this.trustTier = body.get('trust_tier') == null ? null : Integer.valueOf(body.get('trust_tier'));
        this.approvalExpiresAt = OpenBoxIds.parseTimestamp(asString(body.get('approval_expiration_time')));

        Map<String, Object> guardrails = asMap(body.get('guardrails_result'));
        this.guardrailsPassed = guardrails == null ? null : guardrails.get('validation_passed') != false;
        this.redactedInput = guardrails == null ? null : guardrails.get('redacted_input');
        this.guardrailReasons = new List<String>();
        if (guardrails != null && guardrails.get('reasons') instanceof List<Object>) {
            for (Object entry : (List<Object>) guardrails.get('reasons')) {
                Map<String, Object> reasonEntry = asMap(entry);
                if (reasonEntry != null && reasonEntry.get('reason') != null) {
                    guardrailReasons.add(String.valueOf(reasonEntry.get('reason')));
                }
            }
        }

        Map<String, Object> age = asMap(body.get('age_result'));
        this.goalDrifted = age != null && age.get('goal_drifted') == true;
        Object violations = body.get('behavioral_violations');
        this.behavioralViolation = violations instanceof List<Object> && !((List<Object>) violations).isEmpty();
    }

    public Boolean isAllowed() {
        return verdict == OpenBoxVerdict.ALLOW;
    }

    /**
     * The value OpenBox guardrails substituted for an activity_input field (for example a
     * justification with personal data masked), or null when nothing was substituted.
     */
    public Object redactedInputField(String fieldName) {
        Object source = redactedInput;
        if (source instanceof List<Object>) {
            List<Object> items = (List<Object>) source;
            source = items.isEmpty() ? null : items[0];
        }
        Map<String, Object> fields = asMap(source);
        return fields == null ? null : fields.get(fieldName);
    }

    public String summary() {
        return verdict.name() + (String.isBlank(reason) ? '' : ': ' + reason);
    }

    @TestVisible
    private static OpenBoxVerdict parseVerdict(String wire) {
        if (String.isBlank(wire)) {
            throw new OpenBoxContractException('OpenBox evaluation response carried no verdict');
        }
        switch on wire.trim().toLowerCase() {
            when 'allow' {
                return OpenBoxVerdict.ALLOW;
            }
            when 'require_approval' {
                return OpenBoxVerdict.REQUIRE_APPROVAL;
            }
            when 'block' {
                return OpenBoxVerdict.BLOCK;
            }
            when 'halt' {
                return OpenBoxVerdict.HALT;
            }
            when else {
                throw new OpenBoxContractException('Unsupported OpenBox verdict: ' + wire);
            }
        }
    }

    private static String firstNonBlank(String first, String second) {
        return String.isNotBlank(first) ? first : second;
    }

    private static String asString(Object value) {
        return value == null ? null : String.valueOf(value);
    }

    private static Map<String, Object> asMap(Object value) {
        return value instanceof Map<String, Object> ? (Map<String, Object>) value : null;
    }
}
