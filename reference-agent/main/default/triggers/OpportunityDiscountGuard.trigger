/**
 * Makes the OpenBox governed discount action the only path to Opportunity.Discount__c: every other
 * change is rejected unless the user holds OpenBox_Guarded_Field_Direct_Edit.
 */
trigger OpportunityDiscountGuard on Opportunity(before insert, before update) {
    OpenBoxFieldGuard.enforce(Trigger.new, Trigger.oldMap, new Set<SObjectField>{ Opportunity.Discount__c });
}
