/**
 * Obtains the short-lived workload token that OpenBox Core's v3 API requires next to the agent's
 * API key, following the OpenBox SDK's workload-identity contract:
 *
 *   1. GET /api/v3/auth/bootstrap (API key only) names the Keycloak client, key id and issuer.
 *   2. Salesforce signs an RFC 7523 client assertion (RS256, 60 s) with the private key of the
 *      certificate configured in Workload_Certificate__c. Salesforce generated that key and never
 *      exports it; OpenBox holds only the public half.
 *   3. The assertion is exchanged at the issuer's token endpoint (client_credentials grant).
 *
 * Trust is pinned: a bootstrap that names any issuer other than Identity_Issuer__c is refused, so a
 * tampered Core response cannot redirect the assertion. The token endpoint is reached through the
 * OpenBox_Identity Remote Site Setting; it authenticates the client by the assertion alone. The token is cached for the transaction
 * and refreshed 30 seconds before it expires. Every failure raises; nothing is ever downgraded.
 */
public inherited sharing class OpenBoxWorkloadIdentity {
    public static final String TOKEN_HEADER = 'X-OpenBox-Workload-Token';
    public static final String BOOTSTRAP_PATH = '/api/v3/auth/bootstrap';

    private static final Integer CONTRACT_VERSION = 3;
    private static final Integer ASSERTION_LIFETIME_SECONDS = 60;
    private static final Integer REFRESH_SKEW_SECONDS = 30;
    private static final Integer MAX_TOKEN_CACHE_SECONDS = 300;
    private static final String TOKEN_PATH_SUFFIX = '/protocol/openid-connect/token';
    private static final String ASSERTION_TYPE = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer';

    /** Signs the client assertion. Production uses a Salesforce certificate; tests substitute it. */
    public interface Signer {
        Blob sign(Blob input);
    }

    public class CertificateSigner implements Signer {
        private final String certificateName;

        public CertificateSigner(String certificateName) {
            this.certificateName = certificateName;
        }

        public Blob sign(Blob input) {
            return Crypto.signWithCertificate('RSA-SHA256', input, certificateName);
        }
    }

    private class Bootstrap {
        String tokenEndpoint;
        String clientId;
        String kid;
    }

    @TestVisible
    private static Signer signerOverride;

    private static Bootstrap cachedBootstrap;
    private static String cachedToken;
    private static Datetime cachedTokenExpiry;

    private final OpenBoxSettings settings;
    private final String issuer;
    private final Signer signer;

    public OpenBoxWorkloadIdentity() {
        this(OpenBoxSettings.get(), OpenBox_Settings__mdt.getInstance('Default'));
    }

    private OpenBoxWorkloadIdentity(OpenBoxSettings settings, OpenBox_Settings__mdt record) {
        this(
            settings,
            record?.Identity_Issuer__c,
            signerOverride != null
                ? signerOverride
                : String.isBlank(record?.Workload_Certificate__c)
                    ? null
                    : new CertificateSigner(record.Workload_Certificate__c.trim())
        );
    }

    @TestVisible
    private OpenBoxWorkloadIdentity(OpenBoxSettings settings, String issuer, Signer signer) {
        if (String.isBlank(issuer) || signer == null) {
            throw new OpenBoxContractException(
                'OpenBox workload identity is not configured: set Identity_Issuer__c and ' +
                'Workload_Certificate__c on OpenBox_Settings__mdt.Default'
            );
        }
        this.settings = settings;
        this.issuer = issuer.trim().removeEnd('/');
        this.signer = signer;
    }

    /** A valid workload token, fetched at most once per transaction unless it is about to expire. */
    public String accessToken() {
        if (cachedToken != null && Datetime.now().addSeconds(REFRESH_SKEW_SECONDS) < cachedTokenExpiry) {
            return cachedToken;
        }
        Bootstrap bootstrap = bootstrap();
        Map<String, Object> token = send(tokenRequest(bootstrap), 'token exchange');
        String accessToken = stringField(token, 'access_token', 'token exchange');
        if (!'bearer'.equalsIgnoreCase(stringField(token, 'token_type', 'token exchange'))) {
            throw new OpenBoxContractException('OpenBox token exchange returned a non-Bearer token');
        }
        Object expiresIn = token.get('expires_in');
        if (!(expiresIn instanceof Integer || expiresIn instanceof Long || expiresIn instanceof Decimal)) {
            throw new OpenBoxContractException('OpenBox token exchange returned no expires_in');
        }
        Integer lifetime = Integer.valueOf(expiresIn);
        if (lifetime <= REFRESH_SKEW_SECONDS) {
            throw new OpenBoxContractException('OpenBox token exchange returned a token that is about to expire');
        }
        cachedToken = accessToken;
        cachedTokenExpiry = Datetime.now().addSeconds(Math.min(lifetime, MAX_TOKEN_CACHE_SECONDS));
        return cachedToken;
    }

    /** Callouts the next accessToken() call may make, for callers that budget callouts up front. */
    public static Integer pendingCallouts() {
        if (cachedToken != null && Datetime.now().addSeconds(REFRESH_SKEW_SECONDS) < cachedTokenExpiry) {
            return 0;
        }
        return cachedBootstrap == null ? 2 : 1;
    }

    private Bootstrap bootstrap() {
        if (cachedBootstrap != null) {
            return cachedBootstrap;
        }
        HttpRequest request = new HttpRequest();
        request.setMethod('GET');
        request.setEndpoint(settings.endpoint(BOOTSTRAP_PATH));
        request.setTimeout(settings.calloutTimeoutMs);
        request.setHeader('Accept', 'application/json');
        Map<String, Object> document = send(request, 'workload bootstrap');

        if (document.get('bootstrap_version') != CONTRACT_VERSION || document.get('contract_version') != CONTRACT_VERSION) {
            throw new OpenBoxContractException('OpenBox workload bootstrap uses an unsupported contract version');
        }
        String advertisedIssuer = stringField(document, 'issuer', 'workload bootstrap').removeEnd('/');
        if (advertisedIssuer != issuer) {
            throw new OpenBoxContractException(
                'OpenBox workload bootstrap names issuer ' + advertisedIssuer + ', but only ' + issuer + ' is trusted'
            );
        }
        Bootstrap bootstrap = new Bootstrap();
        bootstrap.tokenEndpoint = stringField(document, 'token_endpoint', 'workload bootstrap');
        if (bootstrap.tokenEndpoint != issuer + TOKEN_PATH_SUFFIX) {
            throw new OpenBoxContractException('OpenBox workload bootstrap token endpoint does not belong to the trusted issuer');
        }
        bootstrap.clientId = stringField(document, 'client_id', 'workload bootstrap');
        bootstrap.kid = stringField(document, 'kid', 'workload bootstrap');
        cachedBootstrap = bootstrap;
        return bootstrap;
    }

    private HttpRequest tokenRequest(Bootstrap bootstrap) {
        HttpRequest request = new HttpRequest();
        request.setMethod('POST');
        request.setEndpoint(bootstrap.tokenEndpoint);
        request.setTimeout(settings.calloutTimeoutMs);
        request.setHeader('Content-Type', 'application/x-www-form-urlencoded');
        request.setHeader('Accept', 'application/json');
        request.setBody(
            'grant_type=client_credentials' +
            '&client_id=' + EncodingUtil.urlEncode(bootstrap.clientId, 'UTF-8') +
            '&client_assertion_type=' + EncodingUtil.urlEncode(ASSERTION_TYPE, 'UTF-8') +
            '&client_assertion=' + EncodingUtil.urlEncode(clientAssertion(bootstrap), 'UTF-8')
        );
        return request;
    }

    @TestVisible
    private String clientAssertion(Bootstrap bootstrap) {
        Long issuedAt = Datetime.now().getTime() / 1000;
        Map<String, Object> header = new Map<String, Object>{ 'alg' => 'RS256', 'kid' => bootstrap.kid, 'typ' => 'JWT' };
        Map<String, Object> claims = new Map<String, Object>{
            'aud' => bootstrap.tokenEndpoint,
            'exp' => issuedAt + ASSERTION_LIFETIME_SECONDS,
            'iat' => issuedAt,
            'iss' => bootstrap.clientId,
            'jti' => UUID.randomUUID().toString(),
            'sub' => bootstrap.clientId
        };
        String signingInput = base64Url(Blob.valueOf(JSON.serialize(header))) + '.' + base64Url(Blob.valueOf(JSON.serialize(claims)));
        return signingInput + '.' + base64Url(signer.sign(Blob.valueOf(signingInput)));
    }

    private static Map<String, Object> send(HttpRequest request, String step) {
        if (OpenBoxClient.remainingCallouts() < 1) {
            throw new OpenBoxTransportException('Salesforce callout limit reached before the OpenBox ' + step);
        }
        HttpResponse response;
        try {
            response = new Http().send(request);
        } catch (CalloutException e) {
            throw new OpenBoxTransportException('OpenBox ' + step + ' unreachable: ' + e.getMessage());
        }
        Integer status = response.getStatusCode();
        if (status < 200 || status >= 300) {
            throw new OpenBoxTransportException('OpenBox ' + step + ' returned HTTP ' + status).withStatusCode(status);
        }
        Object parsed;
        try {
            parsed = JSON.deserializeUntyped(response.getBody());
        } catch (JSONException e) {
            throw new OpenBoxContractException('OpenBox ' + step + ' returned malformed JSON');
        }
        if (!(parsed instanceof Map<String, Object>)) {
            throw new OpenBoxContractException('OpenBox ' + step + ' returned a non-object JSON body');
        }
        return (Map<String, Object>) parsed;
    }

    private static String stringField(Map<String, Object> source, String field, String step) {
        Object value = source.get(field);
        if (!(value instanceof String) || String.isBlank((String) value)) {
            throw new OpenBoxContractException('OpenBox ' + step + ' is missing ' + field);
        }
        return ((String) value).trim();
    }

    private static String base64Url(Blob value) {
        return EncodingUtil.base64Encode(value).replace('+', '-').replace('/', '_').removeEnd('=').removeEnd('=');
    }

    @TestVisible
    private static void resetCache() {
        cachedBootstrap = null;
        cachedToken = null;
        cachedTokenExpiry = null;
    }
}
