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
        List<OpenBox_Event_Outbox__c> rows = new List<OpenBox_Event_Outbox__c>();
        Integer sequence = request.Next_Event_Sequence__c == null ? 0 : request.Next_Event_Sequence__c.intValue();
        for (Map<String, Object> event : events) {
            rows.add(
                new OpenBox_Event_Outbox__c(
                    Governed_Request__c = request.Id,
                    Sequence__c = sequence++,
                    Event_Type__c = describe(event),
                    Payload__c = JSON.serialize(event),
                    Status__c = STATUS_QUEUED,
                    Attempts__c = 0
                )
            );
        }
        request.Next_Event_Sequence__c = sequence;
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
