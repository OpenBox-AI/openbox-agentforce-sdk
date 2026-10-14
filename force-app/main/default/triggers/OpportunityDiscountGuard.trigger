trigger OpportunityDiscountGuard on Opportunity(before insert, before update) {
    if (Trigger.isInsert) {
        OpportunityDiscountGuardHandler.beforeInsert(Trigger.new);
    } else {
        OpportunityDiscountGuardHandler.beforeUpdate(Trigger.new, Trigger.oldMap);
    }
}
