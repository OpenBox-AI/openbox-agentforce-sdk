/**
 * One governed Salesforce data operation, projected onto the flat OpenBox Core SpanData contract
 * (the same shape the OpenBox base SDK emits for its database hooks).
 *
 * A span is reported twice under the same span_id: once at stage "started" before the operation
 * runs, where policies, guardrails and behaviour rules can still stop it, and once at stage
 * "completed" after it ran, carrying timing, row count and status. Core stores the two stages as
 * separate rows keyed by (session, span_id, stage), so both halves of every pair are always sent.
 *
 * Wire rules honoured here:
 *  - every common root field is present, null-valued when unknown, never omitted;
 *  - every db_query family root field is present for the same reason;
 *  - started spans carry explicit null end_time and duration_ns;
 *  - times are epoch nanoseconds serialised as JSON integers;
 *  - the db.* OTel attributes are duplicated into attributes, because Core rebuilds the
 *    approval-retry fingerprint from attributes only;
 *  - semantic_type is never sent (Core derives it from db.system plus the SQL verb in the name).
 */
public inherited sharing class OpenBoxSpan {
    public static final String HOOK_TYPE_DB_QUERY = 'db_query';
    public static final String STAGE_STARTED = 'started';
    public static final String STAGE_COMPLETED = 'completed';

    @TestVisible
    private static final String DB_SYSTEM = 'salesforce';
    private static final Integer HTTPS_PORT = 443;
    private static final Long CLOCK_RESOLUTION_NS = 1000000L;

    public final String spanId;
    public final String traceId;
    public final String parentSpanId;
    public final String name;
    public final String operation;
    public final String statement;
    public final Long startTimeNs;

    private final Map<String, Object> attributes;
    private Long endTimeNs;
    private Integer rowCount;
    private String errorType;
    private String errorMessage;

    private OpenBoxSpan(
        String traceId,
        String parentSpanId,
        String operation,
        String objectName,
        String statement,
        Map<String, Object> businessAttributes
    ) {
        this.spanId = OpenBoxIds.newSpanId();
        this.traceId = traceId;
        this.parentSpanId = parentSpanId;
        this.operation = operation;
        this.statement = statement;
        this.name = operation + ' ' + objectName;
        this.startTimeNs = OpenBoxIds.nowNanos();

        this.attributes = new Map<String, Object>{
            'db.system' => DB_SYSTEM,
            'db.name' => UserInfo.getOrganizationId(),
            'db.operation' => operation,
            'db.statement' => statement,
            'db.sql.table' => objectName,
            'server.address' => serverAddress(),
            'server.port' => HTTPS_PORT
        };
        if (businessAttributes != null) {
            this.attributes.putAll(businessAttributes);
        }
    }

    /**
     * A SOQL read. Name "SELECT <object>" makes Core classify it as database_select.
     */
    public static OpenBoxSpan soqlSelect(
        String traceId,
        String parentSpanId,
        String objectName,
        String statement,
        Map<String, Object> businessAttributes
    ) {
        return new OpenBoxSpan(traceId, parentSpanId, 'SELECT', objectName, statement, businessAttributes);
    }

    /**
     * A DML update. Name "UPDATE <object>" makes Core classify it as database_update.
     */
    public static OpenBoxSpan dmlUpdate(
        String traceId,
        String parentSpanId,
        String objectName,
        String statement,
        Map<String, Object> businessAttributes
    ) {
        return new OpenBoxSpan(traceId, parentSpanId, 'UPDATE', objectName, statement, businessAttributes);
    }

    public OpenBoxSpan succeeded(Integer rowCount) {
        this.endTimeNs = OpenBoxIds.nowNanos();
        this.rowCount = rowCount;
        return this;
    }

    public OpenBoxSpan failed(String errorType, String errorMessage) {
        this.endTimeNs = OpenBoxIds.nowNanos();
        this.errorType = errorType;
        this.errorMessage = errorMessage;
        return this;
    }

    public Boolean isFinished() {
        return endTimeNs != null;
    }

    public Map<String, Object> toStartedWire() {
        Map<String, Object> wire = baseWire(STAGE_STARTED);
        wire.put('end_time', null);
        wire.put('duration_ns', null);
        wire.put('status', status('UNSET', null));
        wire.put('error', null);
        wire.put('rowcount', null);
        return wire;
    }

    public Map<String, Object> toCompletedWire() {
        if (!isFinished()) {
            throw new OpenBoxContractException(
                'Span ' + name + ' has not finished; call succeeded() or failed() first'
            );
        }
        Map<String, Object> wire = baseWire(STAGE_COMPLETED);
        // The Apex clock ticks in milliseconds; a sub-millisecond operation is reported as one tick, never as zero.
        Long durationNs = Math.max(endTimeNs - startTimeNs, CLOCK_RESOLUTION_NS);
        wire.put('end_time', startTimeNs + durationNs);
        wire.put('duration_ns', durationNs);
        Boolean ok = errorMessage == null;
        wire.put('status', ok ? status('OK', null) : status('ERROR', errorType + ': ' + errorMessage));
        wire.put('error', ok ? null : errorType + ': ' + errorMessage);
        wire.put('rowcount', rowCount);
        return wire;
    }

    private Map<String, Object> baseWire(String stage) {
        return new Map<String, Object>{
            'span_id' => spanId,
            'trace_id' => traceId,
            'parent_span_id' => parentSpanId,
            'name' => name,
            'kind' => 'CLIENT',
            'stage' => stage,
            'hook_type' => HOOK_TYPE_DB_QUERY,
            'start_time' => startTimeNs,
            'attributes' => attributes.clone(),
            'events' => new List<Object>(),
            'db_system' => DB_SYSTEM,
            'db_name' => attributes.get('db.name'),
            'db_operation' => operation,
            'db_statement' => statement,
            'server_address' => attributes.get('server.address'),
            'server_port' => HTTPS_PORT
        };
    }

    private static Map<String, Object> status(String code, String description) {
        return new Map<String, Object>{ 'code' => code, 'description' => description };
    }

    private static String serverAddress() {
        return Url.getOrgDomainUrl().getHost();
    }
}
