/**
 * Delivers queued OpenBox outbox events in per-request sequence order.
 *
 * Delivery rules:
 *  - events of one request (or, for conversation-level events, of one conversation) are sent
 *    strictly in sequence; a failed event holds back every later event of the same group until it
 *    is delivered or exhausts its attempts;
 *  - an event that exhausts OpenBox_Settings__mdt.Outbox_Max_Attempts__c is marked Failed so its
 *    successors can still close the run in Core;
 *  - Core answers events for a session it has already closed (after a HALT) with a halt verdict and
 *    a nil governance_event_id; those are marked Rejected, not Sent;
 *  - an output guardrail failure reported on a completion is written to the audit trail; the write
 *    it describes has already happened and is never undone.
 *
 * All callouts happen before any DML. Remaining work is picked up by a re-enqueued instance; a
 * duplicate signature keeps at most one dispatcher queued at a time.
 */
public inherited sharing class OpenBoxOutboxDispatcher implements Queueable, Database.AllowsCallouts {
    private static final String SIGNATURE = 'OpenBoxOutboxDispatcher';
    private static final String NIL_UUID = '00000000-0000-0000-0000-000000000000';
    private static final Integer BATCH_SIZE = 50;
    private static final Integer CALLOUT_RESERVE = 2;
    private static final Integer RETRY_DELAY_MINUTES = 1;

    /**
     * Queues a dispatcher unless one is already queued. Safe to call from any transaction that
     * staged outbox rows.
     */
    public static void ensureScheduled() {
        ensureScheduled(0);
    }

    private static void ensureScheduled(Integer delayMinutes) {
        OpenBoxAsync.enqueueOnce(new OpenBoxOutboxDispatcher(), SIGNATURE, delayMinutes);
    }

    public void execute(QueueableContext context) {
        OpenBoxSettings settings = OpenBoxSettings.get();
        OpenBoxClient client = new OpenBoxClient();
        List<OpenBox_Event_Outbox__c> queued = lockNextBatch();

        Set<Id> blockedRequests = new Set<Id>();
        List<OpenBox_Governance_Audit__c> audits = new List<OpenBox_Governance_Audit__c>();
        Boolean workRemains = false;

        for (OpenBox_Event_Outbox__c row : queued) {
            if (
                blockedRequests.contains(groupOf(row)) ||
                OpenBoxClient.remainingCallouts() <= CALLOUT_RESERVE + OpenBoxWorkloadIdentity.pendingCallouts()
            ) {
                workRemains = true;
                continue;
            }
            row.Attempts__c = (row.Attempts__c == null ? 0 : row.Attempts__c) + 1;
            try {
                OpenBoxEvaluationResult result = client.evaluate(
                    (Map<String, Object>) JSON.deserializeUntyped(row.Payload__c)
                );
                Boolean refused =
                    result.verdict == OpenBoxVerdict.HALT &&
                    (String.isBlank(result.governanceEventId) || result.governanceEventId == NIL_UUID);
                row.Status__c = refused ? OpenBoxOutbox.STATUS_REJECTED : OpenBoxOutbox.STATUS_SENT;
                row.Sent_At__c = Datetime.now();
                row.Last_Error__c = refused ? result.reason : null;
                if (result.guardrailsPassed == false) {
                    OpenBox_Governance_Audit__c audit = OpenBoxAudit.entry(
                        row.Governed_Request__r.Request_Id__c,
                        OpenBoxAudit.STAGE_TELEMETRY,
                        'Guardrail_Violation',
                        result,
                        null,
                        null,
                        new Map<String, Object>{ 'event' => row.Event_Type__c }
                    );
                    audit.Agent_Session__c = row.Agent_Session__c;
                    audits.add(audit);
                }
            } catch (OpenBoxException e) {
                row.Last_Error__c = e.getMessage().abbreviate(4000);
                if (row.Attempts__c >= settings.outboxMaxAttempts) {
                    row.Status__c = OpenBoxOutbox.STATUS_FAILED;
                } else {
                    blockedRequests.add(groupOf(row));
                    workRemains = true;
                }
            }
        }

        update queued;
        OpenBoxAudit.link(audits, requestIdsFor(queued));
        insert audits;

        if (workRemains || queued.size() == BATCH_SIZE) {
            ensureScheduled(blockedRequests.isEmpty() ? 0 : RETRY_DELAY_MINUTES);
        }
        OpenBoxApprovalPoller.ensureScheduledIfPending();
    }

    /**
     * Selects the oldest queued events and locks them, so a concurrently running dispatcher can
     * never send the same event twice. SOQL disallows ORDER BY with FOR UPDATE, hence the two
     * queries and the in-memory sort.
     */
    private static List<OpenBox_Event_Outbox__c> lockNextBatch() {
        Map<Id, OpenBox_Event_Outbox__c> candidates = new Map<Id, OpenBox_Event_Outbox__c>(
            [
                SELECT Id
                FROM OpenBox_Event_Outbox__c
                WHERE Status__c = :OpenBoxOutbox.STATUS_QUEUED
                ORDER BY Governed_Request__c, Agent_Session__c, Sequence__c
                LIMIT :BATCH_SIZE
            ]
        );
        List<OutboxRow> rows = new List<OutboxRow>();
        for (OpenBox_Event_Outbox__c locked : [
            SELECT
                Id,
                Governed_Request__c,
                Governed_Request__r.Request_Id__c,
                Agent_Session__c,
                Sequence__c,
                Payload__c,
                Attempts__c,
                Event_Type__c
            FROM OpenBox_Event_Outbox__c
            WHERE Id IN :candidates.keySet() AND Status__c = :OpenBoxOutbox.STATUS_QUEUED
            FOR UPDATE
        ]) {
            rows.add(new OutboxRow(locked));
        }
        rows.sort();
        List<OpenBox_Event_Outbox__c> ordered = new List<OpenBox_Event_Outbox__c>();
        for (OutboxRow row : rows) {
            ordered.add(row.record);
        }
        return ordered;
    }

    private class OutboxRow implements Comparable {
        final OpenBox_Event_Outbox__c record;

        OutboxRow(OpenBox_Event_Outbox__c record) {
            this.record = record;
        }

        public Integer compareTo(Object other) {
            OpenBox_Event_Outbox__c that = ((OutboxRow) other).record;
            String thisRequest = String.valueOf(groupOf(record));
            String thatRequest = String.valueOf(groupOf(that));
            if (thisRequest != thatRequest) {
                return thisRequest < thatRequest ? -1 : 1;
            }
            Decimal delta = record.Sequence__c - that.Sequence__c;
            return delta == 0 ? 0 : (delta < 0 ? -1 : 1);
        }
    }

    /**
     * Events are ordered within their group: one tool call (governed request), or the
     * conversation for events that belong to no single call.
     */
    private static Id groupOf(OpenBox_Event_Outbox__c row) {
        return row.Governed_Request__c != null ? row.Governed_Request__c : row.Agent_Session__c;
    }

    private static Map<String, Id> requestIdsFor(List<OpenBox_Event_Outbox__c> rows) {
        Map<String, Id> ids = new Map<String, Id>();
        for (OpenBox_Event_Outbox__c row : rows) {
            if (row.Governed_Request__c == null) {
                continue;
            }
            ids.put(row.Governed_Request__r.Request_Id__c, row.Governed_Request__c);
        }
        return ids;
    }
}
