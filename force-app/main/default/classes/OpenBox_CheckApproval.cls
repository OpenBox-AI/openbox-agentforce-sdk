/**
 * Agentforce action: checks on any governed call that waited for human approval in OpenBox, and
 * runs it if it was approved. Covers every governed call: registered tools, Apex executors and
 * record writes alike.
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
        for (OpenBox_Governed_Request__c record : [
            SELECT Id, Name, Request_Id__c
            FROM OpenBox_Governed_Request__c
            WHERE (Name IN :references OR Request_Id__c IN :references) AND Requested_By__c = :UserInfo.getUserId()
        ]) {
            byReference.put(record.Name, record);
            byReference.put(record.Request_Id__c, record);
        }

        // Waiting calls are resolved; the others are reported as they stand.
        Set<Id> ids = new Set<Id>();
        for (OpenBox_Governed_Request__c record : byReference.values()) {
            ids.add(record.Id);
        }
        Map<String, OpenBox_GovernedAction.Result> byRequestId = new Map<String, OpenBox_GovernedAction.Result>();
        if (!ids.isEmpty()) {
            for (OpenBoxToolGovernance.Result outcome : new OpenBoxToolGovernance().resolve(ids, true)) {
                byRequestId.put(outcome.requestId, OpenBox_GovernedAction.toResult(outcome));
            }
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
