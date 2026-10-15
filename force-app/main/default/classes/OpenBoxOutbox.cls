/**
 * Transactional outbox for OpenBox events produced after a Salesforce write. Apex forbids callouts
 * once a transaction has performed DML, so the closing half of a governed run (completed spans,
 * ActivityCompleted, the workflow terminal event) is persisted in the same transaction as the write
 * and delivered by OpenBoxOutboxDispatcher. The events commit if and only if the write commits.
 *
 * Sequence numbers are per governed request and continue across transactions, so a run that
 * resumes after an approval stays ordered behind anything it queued earlier.
 */
public inherited sharing class OpenBoxOutbox {
    public static final String STATUS_QUEUED = 'Queued';
    public static final String STATUS_SENT = 'Sent';
    public static final String STATUS_REJECTED = 'Rejected';
    public static final String STATUS_FAILED = 'Failed';

    private OpenBoxOutbox() {
    }

    /**
     * Builds outbox rows for events in emission order and advances the request's sequence cursor.
     * The caller inserts the rows together with its other writes.
     */
    public static List<OpenBox_Event_Outbox__c> stage(
        OpenBox_Governed_Request__c request,
        List<Map<String, Object>> events
    ) {
        Integer sequence = request.Next_Event_Sequence__c == null ? 0 : request.Next_Event_Sequence__c.intValue();
        List<OpenBox_Event_Outbox__c> rows = rows(events, sequence);
        for (OpenBox_Event_Outbox__c row : rows) {
            row.Governed_Request__c = request.Id;
        }
        request.Next_Event_Sequence__c = sequence + rows.size();
        return rows;
    }

    /**
     * Stages conversation-level events (user prompt and subagent signals) that belong to no single
     * tool call. They are ordered per conversation, with their own sequence cursor.
     */
    public static List<OpenBox_Event_Outbox__c> stage(
        OpenBox_Agent_Session__c session,
        List<Map<String, Object>> events
    ) {
        Integer sequence = session.Next_Event_Sequence__c == null ? 0 : session.Next_Event_Sequence__c.intValue();
        List<OpenBox_Event_Outbox__c> rows = rows(events, sequence);
        for (OpenBox_Event_Outbox__c row : rows) {
            row.Agent_Session__c = session.Id;
        }
        session.Next_Event_Sequence__c = sequence + rows.size();
        return rows;
    }

    private static List<OpenBox_Event_Outbox__c> rows(List<Map<String, Object>> events, Integer firstSequence) {
        List<OpenBox_Event_Outbox__c> rows = new List<OpenBox_Event_Outbox__c>();
        Integer sequence = firstSequence;
        for (Map<String, Object> event : events) {
            rows.add(
                new OpenBox_Event_Outbox__c(
                    Sequence__c = sequence++,
                    Event_Type__c = describe(event),
                    Payload__c = JSON.serialize(event),
                    Status__c = STATUS_QUEUED,
                    Attempts__c = 0
                )
            );
        }
        return rows;
    }

    private static String describe(Map<String, Object> event) {
        String eventType = (String) event.get('event_type');
        if (event.get('hook_trigger') == true) {
            List<Object> spans = (List<Object>) event.get('spans');
            Map<String, Object> span = (Map<String, Object>) spans[0];
            return ('Span ' + span.get('name') + ' ' + span.get('stage')).abbreviate(40);
        }
        return eventType;
    }
}
