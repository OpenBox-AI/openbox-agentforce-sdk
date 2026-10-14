/**
 * Transport behaviour of the OpenBox client: endpoint and headers, retry policy and fail-closed
 * error mapping.
 */
@IsTest
private class OpenBoxClientTest {
    private static OpenBoxClient client() {
        OpenBoxTestData.useDefaultSettings();
        return new OpenBoxClient();
    }

    @IsTest
    static void evaluatePostsToV3WithApiKeyCredentialAndWorkloadToken() {
        OpenBoxCoreMock core = OpenBoxCoreMock.install();

        Test.startTest();
        OpenBoxEvaluationResult result = client().evaluate(new Map<String, Object>{ 'event_type' => 'WorkflowStarted' });
        Test.stopTest();

        Assert.isTrue(result.isAllowed());
        HttpRequest sent = core.requests[0];
        Assert.areEqual('callout:OpenBox_Core/api/v3/governance/evaluate', sent.getEndpoint());
        Assert.areEqual('POST', sent.getMethod());
        Assert.areEqual('application/json', sent.getHeader('Content-Type'));
        Assert.areEqual(OpenBoxClient.CLIENT_VERSION, sent.getHeader('X-OpenBox-SDK-Version'));
        Assert.areEqual(64, sent.getHeader('Idempotency-Key').length(), 'idempotency key is the SHA-256 of the body');
        Assert.isNull(sent.getHeader('Authorization'), 'the API key is injected by the Named Credential, never by Apex');
        Assert.areEqual(OpenBoxCoreMock.WORKLOAD_TOKEN, sent.getHeader(OpenBoxWorkloadIdentity.TOKEN_HEADER));
    }

    @IsTest
    static void workloadTokenIsFetchedOncePerTransaction() {
        OpenBoxCoreMock core = OpenBoxCoreMock.install();

        Test.startTest();
        OpenBoxClient openBox = client();
        openBox.evaluate(new Map<String, Object>{ 'event_type' => 'WorkflowStarted' });
        openBox.evaluate(new Map<String, Object>{ 'event_type' => 'SignalReceived' });
        Integer pendingAfter = OpenBoxWorkloadIdentity.pendingCallouts();
        Test.stopTest();

        Assert.areEqual(2, core.requests.size());
        Assert.areEqual(2, core.identityRequests.size(), 'one bootstrap and one token exchange for the transaction');
        Assert.areEqual(0, pendingAfter, 'a cached token needs no further callouts');

        HttpRequest bootstrap = core.identityRequests[0];
        Assert.areEqual('GET', bootstrap.getMethod());
        Assert.areEqual('callout:OpenBox_Core/api/v3/auth/bootstrap', bootstrap.getEndpoint());

        HttpRequest exchange = core.identityRequests[1];
        Assert.areEqual(OpenBoxCoreMock.ISSUER + '/protocol/openid-connect/token', exchange.getEndpoint());
        Map<String, String> form = new Map<String, String>();
        for (String pair : exchange.getBody().split('&')) {
            List<String> parts = pair.split('=', 2);
            form.put(parts[0], EncodingUtil.urlDecode(parts[1], 'UTF-8'));
        }
        Assert.areEqual('client_credentials', form.get('grant_type'));
        Assert.areEqual('openbox-agent-test', form.get('client_id'));
        Assert.areEqual('urn:ietf:params:oauth:client-assertion-type:jwt-bearer', form.get('client_assertion_type'));

        List<String> jwt = form.get('client_assertion').split('\\.');
        Assert.areEqual(3, jwt.size());
        Map<String, Object> header = decodeSegment(jwt[0]);
        Map<String, Object> claims = decodeSegment(jwt[1]);
        Assert.areEqual(new Map<String, Object>{ 'alg' => 'RS256', 'kid' => 'salesforce-test', 'typ' => 'JWT' }, header);
        Assert.areEqual(OpenBoxCoreMock.ISSUER + '/protocol/openid-connect/token', claims.get('aud'));
        Assert.areEqual('openbox-agent-test', claims.get('iss'));
        Assert.areEqual('openbox-agent-test', claims.get('sub'));
        Assert.areEqual(
            60,
            Long.valueOf(String.valueOf(claims.get('exp'))) - Long.valueOf(String.valueOf(claims.get('iat'))),
            'assertions live for 60 seconds'
        );
        Assert.isNotNull(claims.get('jti'));
    }

    @IsTest
    static void untrustedIssuerIsRefusedBeforeAnyAssertionIsSent() {
        OpenBoxCoreMock core = OpenBoxCoreMock.install().advertiseIssuer('https://attacker.example/realms/openbox');

        Test.startTest();
        try {
            client().evaluate(new Map<String, Object>{ 'event_type' => 'WorkflowStarted' });
            Assert.fail('a bootstrap naming an untrusted issuer must fail closed');
        } catch (OpenBoxContractException e) {
            Assert.isTrue(e.getMessage().contains('only ' + OpenBoxCoreMock.ISSUER + ' is trusted'));
        }
        Test.stopTest();

        Assert.areEqual(1, core.identityRequests.size(), 'no token exchange happens');
        Assert.isTrue(core.requests.isEmpty(), 'no governance request is sent');
    }

    @IsTest
    static void rejectedTokenExchangeFailsClosed() {
        OpenBoxCoreMock core = OpenBoxCoreMock.install().failIdentity(401);

        Test.startTest();
        try {
            client().evaluate(new Map<String, Object>{ 'event_type' => 'WorkflowStarted' });
            Assert.fail('without a workload token nothing may be evaluated');
        } catch (OpenBoxTransportException e) {
            Assert.areEqual(401, e.statusCode);
        }
        Test.stopTest();
        Assert.isTrue(core.requests.isEmpty());
    }

    @IsTest
    static void missingWorkloadConfigurationIsRejected() {
        try {
            new OpenBoxWorkloadIdentity(OpenBoxSettings.get(), '', null);
            Assert.fail('a workload identity needs an issuer and a signer');
        } catch (OpenBoxContractException e) {
            Assert.isTrue(e.getMessage().contains('Workload_Certificate__c'));
        }
    }

    private static Map<String, Object> decodeSegment(String segment) {
        String base64 = segment.replace('-', '+').replace('_', '/');
        while (Math.mod(base64.length(), 4) != 0) {
            base64 += '=';
        }
        return (Map<String, Object>) JSON.deserializeUntyped(EncodingUtil.base64Decode(base64).toString());
    }

    @IsTest
    static void gatewayErrorIsRetriedOnceWithSameKey() {
        OpenBoxCoreMock core = OpenBoxCoreMock.install().failNext(1, 502);

        Test.startTest();
        OpenBoxEvaluationResult result = client()
            .evaluate(new Map<String, Object>{ 'event_type' => 'WorkflowStarted' });
        Test.stopTest();

        Assert.isTrue(result.isAllowed());
        Assert.areEqual(2, core.requests.size());
        Assert.areEqual(core.requests[0].getHeader('Idempotency-Key'), core.requests[1].getHeader('Idempotency-Key'));
    }

    @IsTest
    static void clientErrorIsNotRetried() {
        OpenBoxCoreMock core = OpenBoxCoreMock.install().failNext(5, 401);

        Test.startTest();
        try {
            client().evaluate(new Map<String, Object>{ 'event_type' => 'WorkflowStarted' });
            Assert.fail('a 401 must raise');
        } catch (OpenBoxTransportException e) {
            Assert.areEqual(401, e.statusCode);
            Assert.isTrue(e.getMessage().contains('scripted failure'), 'the Core error body is surfaced');
        }
        Test.stopTest();
        Assert.areEqual(1, core.requests.size());
    }

    @IsTest
    static void nonObjectJsonIsContractViolation() {
        OpenBoxCoreMock.install().answerRaw('[1,2]');
        Test.startTest();
        try {
            client().evaluate(new Map<String, Object>());
            Assert.fail('a JSON array is not a valid answer');
        } catch (OpenBoxContractException e) {
            Assert.isTrue(e.getMessage().contains('non-object'));
        }
        Test.stopTest();
    }

    @IsTest
    static void emptyBodyIsContractViolation() {
        OpenBoxCoreMock.install().answerRaw('');
        Test.startTest();
        try {
            client().evaluate(new Map<String, Object>());
            Assert.fail('an empty answer is not a decision');
        } catch (OpenBoxContractException e) {
            Assert.isTrue(e.getMessage().contains('empty'));
        }
        Test.stopTest();
    }

    @IsTest
    static void approvalPollAddressesActivity() {
        OpenBoxCoreMock core = OpenBoxCoreMock.install().answerApproval('allow', 'ok');

        Test.startTest();
        OpenBoxApprovalResult result = client().pollApproval('wf', 'run', 'act');
        Test.stopTest();

        Assert.areEqual(OpenBoxApprovalResult.State.APPROVED, result.status);
        Assert.areEqual('callout:OpenBox_Core/api/v3/governance/approval', core.requests[0].getEndpoint());
        Assert.areEqual(
            new Map<String, Object>{ 'workflow_id' => 'wf', 'run_id' => 'run', 'activity_id' => 'act' },
            core.approvalPolls[0]
        );
    }

    @IsTest
    static void settingsAreBoundedAndValidated() {
        OpenBoxSettings bounded = new OpenBoxSettings('NC', null, 'Type', null, 999999, 99, 0, null);
        Assert.areEqual(120000, bounded.calloutTimeoutMs, 'Apex caps a callout at 120 seconds');
        Assert.areEqual(10, bounded.approvalPollIntervalMinutes, 'queueable delays are at most 10 minutes');
        Assert.areEqual(1, bounded.maxRequestsPerTransaction);
        Assert.areEqual(5, bounded.outboxMaxAttempts);
        Assert.areEqual('Type', bounded.agentName, 'agent name defaults to the workflow type');
        try {
            new OpenBoxSettings('', null, 'Type', null, null, null, null, null);
            Assert.fail('a Named Credential is mandatory');
        } catch (OpenBoxContractException e) {
            Assert.isTrue(e.getMessage().contains('Named_Credential__c'));
        }
    }

    @IsTest
    static void deployedSettingsRecordResolves() {
        OpenBoxSettings.instance = null;
        OpenBoxSettings settings = OpenBoxSettings.get();
        Assert.areEqual('OpenBox_Core', settings.namedCredential);
        Assert.areEqual('callout:OpenBox_Core/x', settings.endpoint('/x'));
    }
}
