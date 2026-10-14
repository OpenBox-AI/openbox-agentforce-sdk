/**
 * Scripted stand-in for OpenBox Core and the OpenBox identity provider in Apex tests. Records every
 * governance request it receives, answers evaluate calls with verdicts chosen by event type,
 * activity type and span, and answers approval polls from a queue. Defaults to "allow" so a test
 * scripts only the decision it is about. Workload bootstrap and token exchange are answered
 * separately (identityRequests) so governance assertions never count them.
 */
@IsTest
public class OpenBoxCoreMock implements HttpCalloutMock {
    public final List<Map<String, Object>> evaluated = new List<Map<String, Object>>();
    public final List<Map<String, Object>> approvalPolls = new List<Map<String, Object>>();
    public final List<HttpRequest> requests = new List<HttpRequest>();
    public final List<HttpRequest> identityRequests = new List<HttpRequest>();

    public static final String ISSUER = 'https://identity.openbox.ai/realms/openbox';
    public static final String WORKLOAD_TOKEN = 'workload-token';

    private final Map<String, Map<String, Object>> scripted = new Map<String, Map<String, Object>>();
    private final List<Map<String, Object>> approvalAnswers = new List<Map<String, Object>>();
    private Integer failuresRemaining = 0;
    private Integer failureStatus;
    private String rawBodyOverride;
    private Boolean throwCalloutException = false;
    private Integer eventCounter = 0;
    private Integer identityFailureStatus;
    private String bootstrapIssuer = ISSUER;

    private class StubSigner implements OpenBoxWorkloadIdentity.Signer {
        public Blob sign(Blob input) {
            return Crypto.generateDigest('SHA-256', input);
        }
    }

    public static OpenBoxCoreMock install() {
        OpenBoxCoreMock mock = new OpenBoxCoreMock();
        Test.setMock(HttpCalloutMock.class, mock);
        OpenBoxWorkloadIdentity.signerOverride = new StubSigner();
        OpenBoxWorkloadIdentity.resetCache();
        return mock;
    }

    /** Makes every workload bootstrap and token exchange answer with the given HTTP status. */
    public OpenBoxCoreMock failIdentity(Integer statusCode) {
        identityFailureStatus = statusCode;
        return this;
    }

    /** Makes the workload bootstrap advertise a different issuer than the one Salesforce trusts. */
    public OpenBoxCoreMock advertiseIssuer(String issuer) {
        bootstrapIssuer = issuer;
        return this;
    }

    /**
     * Scripts the verdict for plain ActivityStarted events of an activity type.
     */
    public OpenBoxCoreMock onActivityStarted(String activityType, String verdict, String reason) {
        return script('ActivityStarted|' + activityType, verdict, reason, null);
    }

    public OpenBoxCoreMock onActivityStarted(String activityType, Map<String, Object> response) {
        scripted.put('ActivityStarted|' + activityType, response);
        return this;
    }

    public OpenBoxCoreMock onActivityCompleted(String activityType, Map<String, Object> response) {
        scripted.put('ActivityCompleted|' + activityType, response);
        return this;
    }

    /**
     * Scripts the verdict for a started-stage span whose name starts with the given SQL verb.
     */
    public OpenBoxCoreMock onSpanStarted(String operation, String verdict, String reason) {
        return script('span|' + operation + '|started', verdict, reason, null);
    }

    public OpenBoxCoreMock onWorkflowStarted(String verdict, String reason) {
        return script('WorkflowStarted|', verdict, reason, null);
    }

    public OpenBoxCoreMock withApprovalWindow(String key, Datetime expiresAt) {
        scripted.get(key).put('approval_expiration_time', OpenBoxIds.timestamp(expiresAt));
        return this;
    }

    public OpenBoxCoreMock answerApproval(String action, String reason) {
        approvalAnswers.add(
            new Map<String, Object>{
                'id' => UUID.randomUUID().toString(),
                'action' => action,
                'reason' => reason,
                'approval_expiration_time' => OpenBoxIds.timestamp(Datetime.now().addHours(1))
            }
        );
        return this;
    }

    public OpenBoxCoreMock failNext(Integer count, Integer statusCode) {
        failuresRemaining = count;
        failureStatus = statusCode;
        return this;
    }

    public OpenBoxCoreMock answerRaw(String body) {
        rawBodyOverride = body;
        return this;
    }

    public OpenBoxCoreMock throwCalloutExceptions() {
        throwCalloutException = true;
        return this;
    }

    public OpenBoxCoreMock healthy() {
        failuresRemaining = 0;
        rawBodyOverride = null;
        throwCalloutException = false;
        return this;
    }

    public HttpResponse respond(HttpRequest request) {
        if (
            request.getEndpoint().endsWith(OpenBoxWorkloadIdentity.BOOTSTRAP_PATH) ||
            request.getEndpoint().endsWith('/protocol/openid-connect/token')
        ) {
            return identityResponse(request);
        }
        requests.add(request);
        if (throwCalloutException) {
            throw new CalloutException('Read timed out');
        }
        HttpResponse response = new HttpResponse();
        response.setHeader('Content-Type', 'application/json');
        if (failuresRemaining > 0) {
            failuresRemaining--;
            response.setStatusCode(failureStatus);
            response.setBody('{"code":' + failureStatus + ',"message":"scripted failure"}');
            return response;
        }
        if (rawBodyOverride != null) {
            response.setStatusCode(200);
            response.setBody(rawBodyOverride);
            return response;
        }

        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(request.getBody());
        response.setStatusCode(200);
        if (request.getEndpoint().endsWith(OpenBoxClient.APPROVAL_PATH)) {
            approvalPolls.add(body);
            Map<String, Object> answer = approvalAnswers.isEmpty()
                ? new Map<String, Object>{ 'id' => UUID.randomUUID().toString(), 'action' => 'require_approval' }
                : approvalAnswers.remove(0);
            response.setBody(JSON.serialize(answer));
            return response;
        }
        evaluated.add(body);
        response.setBody(JSON.serialize(answerFor(body)));
        return response;
    }

    private HttpResponse identityResponse(HttpRequest request) {
        identityRequests.add(request);
        HttpResponse response = new HttpResponse();
        response.setHeader('Content-Type', 'application/json');
        if (identityFailureStatus != null) {
            response.setStatusCode(identityFailureStatus);
            response.setBody('{"error":"invalid_client"}');
            return response;
        }
        response.setStatusCode(200);
        if (request.getMethod() == 'GET') {
            response.setBody(
                JSON.serialize(
                    new Map<String, Object>{
                        'bootstrap_version' => 3,
                        'contract_version' => 3,
                        'issuer' => bootstrapIssuer,
                        'token_endpoint' => bootstrapIssuer + '/protocol/openid-connect/token',
                        'audience' => 'openbox-core',
                        'client_id' => 'openbox-agent-test',
                        'kid' => 'salesforce-test'
                    }
                )
            );
        } else {
            response.setBody(
                JSON.serialize(
                    new Map<String, Object>{ 'access_token' => WORKLOAD_TOKEN, 'token_type' => 'Bearer', 'expires_in' => 300 }
                )
            );
        }
        return response;
    }

    // ── Assertion helpers ───────────────────────────────────────────────────────────────────

    public List<Map<String, Object>> eventsOfType(String eventType) {
        List<Map<String, Object>> matches = new List<Map<String, Object>>();
        for (Map<String, Object> event : evaluated) {
            if (event.get('event_type') == eventType && event.get('hook_trigger') != true) {
                matches.add(event);
            }
        }
        return matches;
    }

    public List<Map<String, Object>> spans() {
        List<Map<String, Object>> found = new List<Map<String, Object>>();
        for (Map<String, Object> event : evaluated) {
            if (event.get('hook_trigger') == true) {
                found.add((Map<String, Object>) ((List<Object>) event.get('spans'))[0]);
            }
        }
        return found;
    }

    public List<String> eventSequence() {
        List<String> sequence = new List<String>();
        for (Map<String, Object> event : evaluated) {
            if (event.get('hook_trigger') == true) {
                Map<String, Object> span = (Map<String, Object>) ((List<Object>) event.get('spans'))[0];
                sequence.add('span:' + span.get('name') + ':' + span.get('stage'));
            } else {
                sequence.add(event.get('event_type') + ':' + event.get('activity_type'));
            }
        }
        return sequence;
    }

    private OpenBoxCoreMock script(String key, String verdict, String reason, Datetime expiresAt) {
        Map<String, Object> response = new Map<String, Object>{
            'verdict' => verdict,
            'action' => verdict,
            'reason' => reason
        };
        if (verdict == 'require_approval') {
            response.put(
                'approval_expiration_time',
                OpenBoxIds.timestamp(expiresAt == null ? Datetime.now().addMinutes(30) : expiresAt)
            );
        }
        scripted.put(key, response);
        return this;
    }

    private Map<String, Object> answerFor(Map<String, Object> body) {
        String eventType = (String) body.get('event_type');
        String key;
        if (body.get('hook_trigger') == true) {
            Map<String, Object> span = (Map<String, Object>) ((List<Object>) body.get('spans'))[0];
            key = 'span|' + String.valueOf(span.get('name')).substringBefore(' ') + '|' + span.get('stage');
        } else if (eventType == 'WorkflowStarted') {
            key = 'WorkflowStarted|';
        } else {
            key = eventType + '|' + body.get('activity_type');
        }
        Map<String, Object> answer = scripted.containsKey(key)
            ? scripted.get(key).clone()
            : new Map<String, Object>{ 'verdict' => 'allow', 'action' => 'allow' };
        eventCounter++;
        answer.put('governance_event_id', '00000000-0000-4000-8000-' + String.valueOf(eventCounter).leftPad(12, '0'));
        answer.put('risk_score', 0);
        answer.put('fallback_used', false);
        return answer;
    }
}
