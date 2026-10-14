/**
 * Resolved deployment configuration, read from the OpenBox_Settings__mdt "Default" record.
 * Secrets are never part of this configuration: the runtime key lives only in the
 * OpenBox_Core_Auth External Credential and is injected by the platform at callout time.
 */
public inherited sharing class OpenBoxSettings {
    private static final String DEFAULT_RECORD = 'Default';
    private static final Integer MAX_CALLOUT_TIMEOUT_MS = 120000;

    public final String namedCredential;
    public final String agentName;
    public final String workflowType;
    public final String taskQueue;
    public final Integer calloutTimeoutMs;
    public final Integer approvalPollIntervalMinutes;
    public final Integer maxRequestsPerTransaction;
    public final Integer outboxMaxAttempts;

    @TestVisible
    private static OpenBoxSettings instance;

    @TestVisible
    private OpenBoxSettings(
        String namedCredential,
        String agentName,
        String workflowType,
        String taskQueue,
        Integer calloutTimeoutMs,
        Integer approvalPollIntervalMinutes,
        Integer maxRequestsPerTransaction,
        Integer outboxMaxAttempts
    ) {
        this.namedCredential = required(namedCredential, 'Named_Credential__c');
        this.workflowType = required(workflowType, 'Workflow_Type__c');
        this.agentName = String.isBlank(agentName) ? workflowType : agentName;
        this.taskQueue = taskQueue;
        this.calloutTimeoutMs = bounded(calloutTimeoutMs, 1000, MAX_CALLOUT_TIMEOUT_MS, 10000);
        // System.enqueueJob accepts a minimum delay of 0 to 10 minutes.
        this.approvalPollIntervalMinutes = bounded(approvalPollIntervalMinutes, 1, 10, 1);
        this.maxRequestsPerTransaction = bounded(maxRequestsPerTransaction, 1, 10, 5);
        this.outboxMaxAttempts = bounded(outboxMaxAttempts, 1, 20, 5);
    }

    public static OpenBoxSettings get() {
        if (instance == null) {
            OpenBox_Settings__mdt record = OpenBox_Settings__mdt.getInstance(DEFAULT_RECORD);
            if (record == null) {
                throw new OpenBoxContractException('OpenBox_Settings__mdt record "Default" is missing');
            }
            instance = new OpenBoxSettings(
                record.Named_Credential__c,
                record.Agent_Name__c,
                record.Workflow_Type__c,
                record.Task_Queue__c,
                toInteger(record.Callout_Timeout_Ms__c),
                toInteger(record.Approval_Poll_Interval_Minutes__c),
                toInteger(record.Max_Requests_Per_Transaction__c),
                toInteger(record.Outbox_Max_Attempts__c)
            );
        }
        return instance;
    }

    public String endpoint(String path) {
        return 'callout:' + namedCredential + path;
    }

    private static String required(String value, String fieldName) {
        if (String.isBlank(value)) {
            throw new OpenBoxContractException('OpenBox_Settings__mdt.' + fieldName + ' must be set');
        }
        return value.trim();
    }

    private static Integer bounded(Integer value, Integer minimum, Integer maximum, Integer fallback) {
        if (value == null) {
            return fallback;
        }
        return Math.min(Math.max(value, minimum), maximum);
    }

    private static Integer toInteger(Decimal value) {
        return value == null ? null : value.intValue();
    }
}
