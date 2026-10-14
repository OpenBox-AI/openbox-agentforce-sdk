/**
 * Agentforce custom action: report on a governed discount request and, if it was waiting for a
 * human, resolve it now. An approved request is applied in this call (after the same locked
 * re-read and access checks as an immediate change); a rejected or expired one is closed with no
 * change. Calling it repeatedly is safe: a request is applied at most once.
 */
public with sharing class OpenBox_CheckDiscountApproval {
    public class Request {
        @InvocableVariable(
            label='Request Number or ID'
            description='The governed request reference returned when the discount was requested, for example GR-000042, or its request ID.'
            required=true
        )
        public String requestReference;
    }

    @InvocableMethod(
        label='Check Discount Approval (OpenBox Governed)'
        description='Checks a discount request that needed human approval in OpenBox. Applies it if approved, closes it if rejected or expired, and reports the current status. Relay the message to the user.'
        category='OpenBox Governance'
    )
    public static List<OpenBox_GovernedDiscountUpdate.Result> checkApproval(List<Request> requests) {
        Map<String, Integer> positionByReference = new Map<String, Integer>();
        for (Integer i = 0; i < requests.size(); i++) {
            String reference = requests[i].requestReference == null ? null : requests[i].requestReference.trim();
            positionByReference.put(reference, i);
        }

        Map<Id, String> referenceByRequestId = new Map<Id, String>();
        Map<String, String> referenceByRequestKey = new Map<String, String>();
        Set<String> references = positionByReference.keySet();
        // Agents may only check requests their own user made.
        for (OpenBox_Governed_Request__c record : [
            SELECT Id, Name, Request_Id__c
            FROM OpenBox_Governed_Request__c
            WHERE (Name IN :references OR Request_Id__c IN :references) AND Requested_By__c = :UserInfo.getUserId()
        ]) {
            String reference = references.contains(record.Name) ? record.Name : record.Request_Id__c;
            referenceByRequestId.put(record.Id, reference);
            referenceByRequestKey.put(record.Request_Id__c, reference);
        }

        List<OpenBox_GovernedDiscountUpdate.Result> results = new List<OpenBox_GovernedDiscountUpdate.Result>(
            requests.size()
        );
        if (!referenceByRequestId.isEmpty()) {
            for (
                OpenBoxDiscountGovernance.Outcome outcome : new OpenBoxDiscountGovernance()
                    .resolvePending(referenceByRequestId.keySet())
            ) {
                Integer position = positionByReference.get(referenceByRequestKey.get(outcome.requestId));
                if (position != null) {
                    results[position] = OpenBox_GovernedDiscountUpdate.toResult(outcome);
                }
            }
        }
        for (Integer i = 0; i < results.size(); i++) {
            if (results[i] == null) {
                results[i] = notFound(requests[i].requestReference);
            }
        }
        return results;
    }

    private static OpenBox_GovernedDiscountUpdate.Result notFound(String reference) {
        OpenBox_GovernedDiscountUpdate.Result result = new OpenBox_GovernedDiscountUpdate.Result();
        result.status = 'Not_Found';
        result.changed = false;
        result.message = 'No discount request ' + reference + ' was found for this user.';
        return result;
    }
}