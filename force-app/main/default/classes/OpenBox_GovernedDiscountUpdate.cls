/**
 * Agentforce custom action: change an Opportunity discount under OpenBox governance.
 *
 * This is the only path an agent has to Opportunity.Discount__c. OpenBox decides every request
 * before anything changes: routine discounts apply immediately, forbidden ones are refused, and
 * large ones wait for a human approver in OpenBox and are applied automatically once approved.
 */
public with sharing class OpenBox_GovernedDiscountUpdate {
    public class Request {
        @InvocableVariable(
            label='Opportunity ID'
            description='Record ID of the Opportunity whose discount should change.'
            required=true
        )
        public Id opportunityId;

        @InvocableVariable(
            label='Proposed Discount (%)'
            description='The new discount as a percentage between 0 and 100, for example 12.5 for 12.5%.'
            required=true
        )
        public Decimal proposedDiscount;

        @InvocableVariable(
            label='Business Justification'
            description='Why the customer should receive this discount, in the words of the user who asked for it.'
        )
        public String justification;

        @InvocableVariable(
            label='User Request'
            description='The user message that led to this change, verbatim. Used by OpenBox to check the action matches the user intent.'
        )
        public String userPrompt;

        @InvocableVariable(
            label='Agent Session ID'
            description='Identifier of the current agent conversation, used to correlate governance records.'
        )
        public String agentSessionId;
    }

    public class Result {
        @InvocableVariable(
            label='Status'
            description='Executed, Pending_Approval, Blocked, Halted, Permission_Denied, Stale or Failed.'
        )
        public String status;

        @InvocableVariable(
            label='Discount Changed'
            description='True only when the Opportunity discount was actually updated.'
        )
        public Boolean changed;

        @InvocableVariable(label='Message' description='Plain-language outcome to relay to the user.')
        public String message;

        @InvocableVariable(
            label='OpenBox Decision'
            description='ALLOW, REQUIRE_APPROVAL, BLOCK, HALT, or ERROR when no decision could be obtained.'
        )
        public String decision;

        @InvocableVariable(label='Reason' description='Why OpenBox or Salesforce reached this outcome.')
        public String reason;

        @InvocableVariable(
            label='Request Number'
            description='Governed request reference, for example GR-000042. Use it to check on a pending approval.'
        )
        public String requestNumber;

        @InvocableVariable(label='Request ID' description='Correlation identifier shared by Salesforce and OpenBox.')
        public String requestId;

        @InvocableVariable(
            label='OpenBox Decision ID'
            description='OpenBox governance event identifier of the decision.'
        )
        public String decisionId;

        @InvocableVariable(label='Previous Discount (%)' description='Discount before this request.')
        public Decimal previousDiscount;

        @InvocableVariable(label='Requested Discount (%)' description='Discount requested.')
        public Decimal requestedDiscount;

        @InvocableVariable(label='Approval Expires At' description='When a pending approval lapses.')
        public Datetime approvalExpiresAt;

        @InvocableVariable(
            label='Opportunity Summary'
            description='Current state of the Opportunity as the agent may describe it.'
        )
        public String opportunitySummary;
    }

    @InvocableMethod(
        label='Update Opportunity Discount (OpenBox Governed)'
        description='Changes the discount on an Opportunity after OpenBox authorizes it. Use this for every discount change. The result says whether the discount was changed, refused, or is waiting for human approval; relay its message to the user and never claim a change that was not made.'
        category='OpenBox Governance'
    )
    public static List<Result> updateDiscount(List<Request> requests) {
        List<OpenBoxDiscountGovernance.DiscountRequest> governed = new List<OpenBoxDiscountGovernance.DiscountRequest>();
        for (Request request : requests) {
            OpenBoxDiscountGovernance.DiscountRequest item = new OpenBoxDiscountGovernance.DiscountRequest();
            item.opportunityId = request.opportunityId;
            item.proposedDiscount = request.proposedDiscount;
            item.justification = request.justification;
            item.userPrompt = request.userPrompt;
            item.agentSessionId = request.agentSessionId;
            governed.add(item);
        }
        List<Result> results = new List<Result>();
        for (OpenBoxDiscountGovernance.Outcome outcome : new OpenBoxDiscountGovernance().requestDiscounts(governed)) {
            results.add(toResult(outcome));
        }
        return results;
    }

    public static Result toResult(OpenBoxDiscountGovernance.Outcome outcome) {
        Result result = new Result();
        result.status = outcome.status;
        result.changed = outcome.changed;
        result.message = outcome.message;
        result.decision = outcome.decision;
        result.reason = outcome.reason;
        result.requestNumber = outcome.requestNumber;
        result.requestId = outcome.requestId;
        result.decisionId = outcome.decisionId;
        result.previousDiscount = outcome.previousDiscount;
        result.requestedDiscount = outcome.requestedDiscount;
        result.approvalExpiresAt = outcome.approvalExpiresAt;
        result.opportunitySummary = outcome.opportunitySummary;
        return result;
    }
}