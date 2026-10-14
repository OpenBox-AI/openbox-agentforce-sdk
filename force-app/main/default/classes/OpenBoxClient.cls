/**
 * HTTPS client for the OpenBox Core v3 governance API. Every request carries two credentials: the
 * agent's API key, injected by the OpenBox_Core Named Credential so it never appears in Apex, logs
 * or prompts, and a short-lived workload token from OpenBoxWorkloadIdentity.
 *
 * Fails closed: an unreachable service, a timeout, a non-2xx status, an unparseable body or an
 * unknown verdict raises OpenBoxException. None of these is ever interpreted as an approval.
 *
 * Gateway errors (502/503/504) and connection failures are retried once with the same body and the
 * same Idempotency-Key, so a retried event cannot be recorded twice. Core's own 500s are not
 * retried: the event may already be stored, and a governed write must not proceed on a guess.
 */
public inherited sharing class OpenBoxClient {
    public static final String EVALUATE_PATH = '/api/v3/governance/evaluate';
    public static final String APPROVAL_PATH = '/api/v3/governance/approval';
    public static final String CLIENT_VERSION = '1.0.0';

    private static final String USER_AGENT = 'OpenBox-Salesforce-Agentforce/' + CLIENT_VERSION;
    private static final Set<Integer> RETRYABLE_STATUS = new Set<Integer>{ 502, 503, 504 };
    private static final Integer MAX_ATTEMPTS = 2;
    private static final Integer MAX_ERROR_BODY_CHARS = 500;

    private final OpenBoxSettings settings;
    private final OpenBoxWorkloadIdentity workloadIdentity;

    public OpenBoxClient() {
        this(OpenBoxSettings.get(), new OpenBoxWorkloadIdentity());
    }

    public OpenBoxClient(OpenBoxSettings settings, OpenBoxWorkloadIdentity workloadIdentity) {
        this.settings = settings;
        this.workloadIdentity = workloadIdentity;
    }

    public OpenBoxEvaluationResult evaluate(Map<String, Object> event) {
        return new OpenBoxEvaluationResult(post(EVALUATE_PATH, JSON.serialize(event)));
    }

    public OpenBoxApprovalResult pollApproval(String workflowId, String runId, String activityId) {
        Map<String, Object> body = new Map<String, Object>{
            'workflow_id' => workflowId,
            'run_id' => runId,
            'activity_id' => activityId
        };
        return new OpenBoxApprovalResult(post(APPROVAL_PATH, JSON.serialize(body)), Datetime.now());
    }

    /** Callouts left in this transaction, used by callers to refuse work up front instead of failing half-way. */
    public static Integer remainingCallouts() {
        return Limits.getLimitCallouts() - Limits.getCallouts();
    }

    private Map<String, Object> post(String path, String body) {
        String idempotencyKey = EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(body)));
        String workloadToken = workloadIdentity.accessToken();
        OpenBoxTransportException lastFailure;
        for (Integer attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
            if (remainingCallouts() < 1) {
                throw new OpenBoxTransportException('Salesforce callout limit reached before contacting OpenBox');
            }
            HttpResponse response;
            try {
                response = new Http().send(buildRequest(path, body, idempotencyKey, workloadToken));
            } catch (CalloutException e) {
                lastFailure = new OpenBoxTransportException('OpenBox unreachable: ' + e.getMessage());
                continue;
            }
            Integer status = response.getStatusCode();
            if (status >= 200 && status < 300) {
                return parse(response.getBody());
            }
            lastFailure = new OpenBoxTransportException(
                    'OpenBox ' + path + ' returned HTTP ' + status + ': ' + abbreviate(response.getBody())
                )
                .withStatusCode(status);
            if (!RETRYABLE_STATUS.contains(status)) {
                break;
            }
        }
        throw lastFailure;
    }

    private HttpRequest buildRequest(String path, String body, String idempotencyKey, String workloadToken) {
        HttpRequest request = new HttpRequest();
        request.setMethod('POST');
        request.setEndpoint(settings.endpoint(path));
        request.setTimeout(settings.calloutTimeoutMs);
        request.setHeader('Content-Type', 'application/json');
        request.setHeader('Accept', 'application/json');
        request.setHeader('User-Agent', USER_AGENT);
        request.setHeader('X-OpenBox-SDK-Version', CLIENT_VERSION);
        request.setHeader('Idempotency-Key', idempotencyKey);
        request.setHeader(OpenBoxWorkloadIdentity.TOKEN_HEADER, workloadToken);
        request.setBody(body);
        return request;
    }

    private static Map<String, Object> parse(String body) {
        if (String.isBlank(body)) {
            throw new OpenBoxContractException('OpenBox returned an empty response body');
        }
        Object parsed;
        try {
            parsed = JSON.deserializeUntyped(body);
        } catch (JSONException e) {
            throw new OpenBoxContractException('OpenBox returned malformed JSON: ' + abbreviate(body));
        }
        if (!(parsed instanceof Map<String, Object>)) {
            throw new OpenBoxContractException('OpenBox returned a non-object JSON body');
        }
        return (Map<String, Object>) parsed;
    }

    private static String abbreviate(String value) {
        return value == null ? '' : value.abbreviate(MAX_ERROR_BODY_CHARS);
    }
}
