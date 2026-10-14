/**
 * Marks the Opportunity ids whose Discount__c change has been authorized by OpenBox in the current
 * transaction. OpportunityDiscountGuard rejects every other Discount__c change, which is what
 * makes the governed action the only path an agent has to the field.
 *
 * Authorizations are scoped to a single DML call: callers authorize, write, and revoke in a
 * finally block, so an authorization can never leak to a later, ungoverned update.
 */
public inherited sharing class OpenBoxGovernedWriteContext {
    private static Set<Id> authorizedIds = new Set<Id>();

    private OpenBoxGovernedWriteContext() {
    }

    public static void authorize(Set<Id> opportunityIds) {
        authorizedIds.addAll(opportunityIds);
    }

    public static void revokeAll() {
        authorizedIds.clear();
    }

    public static Boolean isAuthorized(Id opportunityId) {
        return authorizedIds.contains(opportunityId);
    }
}
