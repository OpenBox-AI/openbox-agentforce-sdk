/**
 * Salesforce-side authorization for a governed discount write, evaluated for the requesting user,
 * not the running user. An approved request is executed later by a background job, so the checks
 * must be answered for whoever asked, and they are re-run at execution time because permissions
 * and sharing can change while a request waits for approval.
 *
 * An OpenBox ALLOW never overrides a failure here: both systems must agree before data changes.
 *
 * Field access: agent users hold Discount__c read-only on purpose, so no generic record action
 * can change it. Write access to the field is granted by the OpenBox_Governed_Discount_Update
 * custom permission, which only this governed path honours; read access is still required.
 *
 * Runs without sharing because it inspects setup objects and other users' record access, which the
 * requesting user may not be able to see. It returns decisions only, never data.
 */
public without sharing class OpenBoxAccess {
    @TestVisible
    private static final String GOVERNED_PERMISSION = 'OpenBox_Governed_Discount_Update';

    public class Decision {
        public final Boolean allowed;
        public final String reason;

        private Decision(Boolean allowed, String reason) {
            this.allowed = allowed;
            this.reason = reason;
        }
    }

    private OpenBoxAccess() {
    }

    public static Decision canRequest(Id userId) {
        if (!isActive(userId)) {
            return deny('The requesting user is inactive');
        }
        if (!holdsCustomPermission(userId, GOVERNED_PERMISSION)) {
            return deny('The requesting user lacks the OpenBox Governed Discount Update permission');
        }
        return allow();
    }

    public static Decision canUpdateDiscount(Id userId, Id opportunityId) {
        Decision entitlement = canRequest(userId);
        if (!entitlement.allowed) {
            return entitlement;
        }
        Set<Id> permissionSetIds = permissionSetsOf(userId);
        if (!objectEditable(permissionSetIds)) {
            return deny('The requesting user cannot edit Opportunity records');
        }
        if (!fieldReadable(permissionSetIds)) {
            return deny('The requesting user cannot read Opportunity.Discount__c');
        }
        if (!recordEditable(userId, opportunityId)) {
            return deny('The requesting user has no edit access to this Opportunity');
        }
        return allow();
    }

    private static Boolean isActive(Id userId) {
        List<User> users = [SELECT IsActive FROM User WHERE Id = :userId LIMIT 1];
        return !users.isEmpty() && users[0].IsActive;
    }

    private static Set<Id> permissionSetsOf(Id userId) {
        Set<Id> ids = new Set<Id>();
        for (PermissionSetAssignment assignment : [
            SELECT PermissionSetId
            FROM PermissionSetAssignment
            WHERE AssigneeId = :userId AND (ExpirationDate = NULL OR ExpirationDate > :Datetime.now())
        ]) {
            ids.add(assignment.PermissionSetId);
        }
        return ids;
    }

    private static Boolean holdsCustomPermission(Id userId, String developerName) {
        List<CustomPermission> permissions = [
            SELECT Id
            FROM CustomPermission
            WHERE DeveloperName = :developerName AND NamespacePrefix = NULL
            LIMIT 1
        ];
        if (permissions.isEmpty()) {
            return false;
        }
        return [
                SELECT COUNT()
                FROM SetupEntityAccess
                WHERE SetupEntityId = :permissions[0].Id AND ParentId IN :permissionSetsOf(userId)
            ] > 0;
    }

    private static Boolean objectEditable(Set<Id> permissionSetIds) {
        return [
                SELECT COUNT()
                FROM ObjectPermissions
                WHERE SobjectType = 'Opportunity' AND PermissionsEdit = TRUE AND ParentId IN :permissionSetIds
            ] > 0;
    }

    private static Boolean fieldReadable(Set<Id> permissionSetIds) {
        return [
                SELECT COUNT()
                FROM FieldPermissions
                WHERE
                    SobjectType = 'Opportunity'
                    AND Field = 'Opportunity.Discount__c'
                    AND PermissionsRead = TRUE
                    AND ParentId IN :permissionSetIds
            ] > 0;
    }

    private static Boolean recordEditable(Id userId, Id opportunityId) {
        List<UserRecordAccess> access = [
            SELECT RecordId, HasEditAccess
            FROM UserRecordAccess
            WHERE UserId = :userId AND RecordId = :opportunityId
        ];
        return !access.isEmpty() && access[0].HasEditAccess;
    }

    private static Decision allow() {
        return new Decision(true, null);
    }

    private static Decision deny(String reason) {
        return new Decision(false, reason);
    }
}
