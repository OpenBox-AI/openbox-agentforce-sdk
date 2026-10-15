/**
 * Agentforce action: checks on any governed call that waited for human approval in OpenBox, and
 * runs it if it was approved. Covers registered tools and the discount action alike.
 *
 * Runs as the agent's own user, which is what lets an approved flow or standard action run (the
 * background poller never runs those as itself). Calling it repeatedly is safe: a call runs at
 * most once.
 */
public with sharing class OpenBox_CheckApproval {
    public class Request {
        @InvocableVariable(
            label='Request Number or ID'
            description='The request reference returned when the call needed approval, for example GR-000042.'
            required=true
        )
        public String requestReference;
    }

    @InvocableMethod(
        label='Check Approval (OpenBox Governed)'
        description='Checks a governed call that needed human approval in OpenBox. Runs it if approved, closes it if rejected or expired, and reports the status. Relay the message to the user.'
        category='OpenBox Governance'
    )
    public static List<OpenBox_GovernedAction.Result> check(List<Request> requests) {
        Set<String> references = new Set<String>();
        for (Request request : requests) {
            if (String.isNotBlank(request.requestReference)) {
                references.add(request.requestReference.trim());
            }
        }

        // Agents may only check calls their own user made.
        Map<String, OpenBox_Governed_Request__c> byReference = new Map<String, OpenBox_Governed_Request__c>();
        Set<Id> toolIds = new Set<Id>();
        Set<Id> discountIds = new Set<Id>();
        for (OpenBox_Governed_Request__c record : [
            SELECT Id, Name, Request_Id__c, Tool_Name__c
            FROM OpenBox_Governed_Request__c
            WHERE (Name IN :references OR Request_Id__c IN :references) AND Requested_By__c = :UserInfo.getUserId()
        ]) {
            byReference.put(record.Name, record);
            byReference.put(record.Request_Id__c, record);
            if (record.Tool_Name__c == null) {
                discountIds.add(record.Id);
            } else {
                toolIds.add(record.Id);
            }
        }

        // Each kind writes in its own commit phase, and Apex allows no callout after a write, so one
        // kind is resolved per call; the other is reported as it stands.
        Map<String, OpenBox_GovernedAction.Result> byRequestId = new Map<String, OpenBox_GovernedAction.Result>();
        if (!toolIds.isEmpty()) {
            for (OpenBoxToolGovernance.Result outcome : new OpenBoxToolGovernance().resolve(toolIds, true)) {
                byRequestId.put(outcome.requestId, OpenBox_GovernedAction.toResult(outcome));
            }
        } else if (!discountIds.isEmpty()) {
            for (OpenBoxDiscountGovernance.Outcome outcome : new OpenBoxDiscountGovernance().resolvePending(discountIds)) {
                OpenBox_GovernedAction.Result result = new OpenBox_GovernedAction.Result();
                result.status = outcome.status;
                result.executed = outcome.changed;
                result.message = outcome.message;
                result.verdict = outcome.decision;
                result.reason = outcome.reason;
                result.requestNumber = outcome.requestNumber;
                byRequestId.put(outcome.requestId, result);
            }
        }
        // Calls that were no longer waiting are reported as they stand.
        Set<Id> settled = new Set<Id>();
        for (OpenBox_Governed_Request__c record : byReference.values()) {
            if (!byRequestId.containsKey(record.Request_Id__c)) {
                settled.add(record.Id);
            }
        }
        for (OpenBox_Governed_Request__c record : [
            SELECT Name, Request_Id__c, Status__c, Decision__c, Reason__c, Tool_Name__c, Tool_Output__c
            FROM OpenBox_Governed_Request__c
            WHERE Id IN :settled
        ]) {
            OpenBox_GovernedAction.Result result = new OpenBox_GovernedAction.Result();
            result.status = record.Status__c;
            result.executed = record.Status__c == OpenBoxDiscountGovernance.STATUS_EXECUTED;
            result.verdict = record.Decision__c;
            result.reason = record.Reason__c;
            result.requestNumber = record.Name;
            result.outputJson = record.Tool_Output__c;
            result.message = 'Request ' + record.Name + ' is ' + record.Status__c.replace('_', ' ').toLowerCase() + '.';
            byRequestId.put(record.Request_Id__c, result);
        }

        List<OpenBox_GovernedAction.Result> results = new List<OpenBox_GovernedAction.Result>();
        for (Request request : requests) {
            String reference = request.requestReference == null ? null : request.requestReference.trim();
            OpenBox_Governed_Request__c record = reference == null ? null : byReference.get(reference);
            OpenBox_GovernedAction.Result result = record == null ? null : byRequestId.get(record.Request_Id__c);
            if (result == null) {
                result = new OpenBox_GovernedAction.Result();
                result.status = 'Not_Found';
                result.executed = false;
                result.message = 'No governed request ' + reference + ' was found for this user.';
            }
            results.add(result);
        }
        return results;
    }
}
