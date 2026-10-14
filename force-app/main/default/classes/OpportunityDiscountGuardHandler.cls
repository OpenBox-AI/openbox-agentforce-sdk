/**
 * Enforcement boundary for Opportunity.Discount__c. A discount may be set or changed only by:
 *  - the OpenBox governed action, for the record it was just authorized to write; or
 *  - a user holding the OpenBox_Discount_Direct_Edit custom permission (human administrators).
 *
 * Every other path (standard record actions, flows, API clients, other Apex) is rejected, so an
 * agent cannot reach around OpenBox even if it is given broader field permissions later.
 */
public inherited sharing class OpportunityDiscountGuardHandler {
    @TestVisible
    private static final String DIRECT_EDIT_PERMISSION = 'OpenBox_Discount_Direct_Edit';

    @TestVisible
    private static final String REJECTION_MESSAGE = 'Discount can only be changed through the OpenBox governed discount action.';

    private OpportunityDiscountGuardHandler() {
    }

    public static void beforeInsert(List<Opportunity> records) {
        if (holdsDirectEdit()) {
            return;
        }
        for (Opportunity record : records) {
            if (record.Discount__c != null) {
                record.Discount__c.addError(REJECTION_MESSAGE);
            }
        }
    }

    public static void beforeUpdate(List<Opportunity> records, Map<Id, Opportunity> previous) {
        Boolean directEdit = null;
        for (Opportunity record : records) {
            if (record.Discount__c == previous.get(record.Id).Discount__c) {
                continue;
            }
            if (OpenBoxGovernedWriteContext.isAuthorized(record.Id)) {
                continue;
            }
            if (directEdit == null) {
                directEdit = holdsDirectEdit();
            }
            if (!directEdit) {
                record.Discount__c.addError(REJECTION_MESSAGE);
            }
        }
    }

    private static Boolean holdsDirectEdit() {
        return FeatureManagement.checkPermission(DIRECT_EDIT_PERMISSION);
    }
}
