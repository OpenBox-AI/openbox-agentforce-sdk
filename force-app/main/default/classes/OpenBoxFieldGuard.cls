/**
 * Enforcement boundary for fields an agent may change only through OpenBox. Call it from a before
 * insert / before update trigger on the object; a guarded field may then be set or changed only by:
 *  - an OpenBox governed write, for the record and field it was just authorized to write; or
 *  - a user holding the direct-edit custom permission (human administrators).
 *
 * Every other path (standard record actions, flows, API clients, other Apex) is rejected, so an
 * agent cannot reach around OpenBox even if it is given broader field permissions later.
 *
 *   trigger AccountCreditLimitGuard on Account(before insert, before update) {
 *       OpenBoxFieldGuard.enforce(Trigger.new, Trigger.oldMap, new Set<SObjectField>{ Account.Credit_Limit__c });
 *   }
 */
public inherited sharing class OpenBoxFieldGuard {
    /** Held by people who may edit guarded fields directly. Never assign it to agent users. */
    public static final String DIRECT_EDIT_PERMISSION = 'OpenBox_Guarded_Field_Direct_Edit';

    @TestVisible
    private static final String REJECTION_MESSAGE = '{0} can only be changed through an OpenBox governed action.';

    @TestVisible
    private static Boolean directEditOverride;

    private OpenBoxFieldGuard() {
    }

    /**
     * Rejects ungoverned changes to the fields. oldRecords is null on insert, where any non-null
     * value of a guarded field counts as a change.
     */
    public static void enforce(List<SObject> records, Map<Id, SObject> oldRecords, Set<SObjectField> fields) {
        enforce(records, oldRecords, fields, DIRECT_EDIT_PERMISSION);
    }

    /** As enforce(), with a custom permission of your own as the direct-edit exemption. */
    public static void enforce(
        List<SObject> records,
        Map<Id, SObject> oldRecords,
        Set<SObjectField> fields,
        String directEditPermission
    ) {
        Boolean directEdit = null;
        for (SObject record : records) {
            SObject previous = oldRecords == null || record.Id == null ? null : oldRecords.get(record.Id);
            for (SObjectField field : fields) {
                Object value = record.get(field);
                Boolean changed = previous == null ? value != null : value != previous.get(field);
                if (!changed) {
                    continue;
                }
                String name = field.getDescribe().getName();
                if (record.Id != null && OpenBoxGovernedWriteContext.isAuthorized(record.Id, name)) {
                    continue;
                }
                if (directEdit == null) {
                    directEdit = holdsDirectEdit(directEditPermission);
                }
                if (!directEdit) {
                    record.addError(field, String.format(REJECTION_MESSAGE, new List<Object>{ field.getDescribe().getLabel() }));
                }
            }
        }
    }

    private static Boolean holdsDirectEdit(String permission) {
        if (directEditOverride != null) {
            return directEditOverride;
        }
        return String.isNotBlank(permission) && FeatureManagement.checkPermission(permission);
    }
}
