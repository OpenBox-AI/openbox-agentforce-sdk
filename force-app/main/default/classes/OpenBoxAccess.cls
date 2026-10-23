/**
 * Salesforce-side authorization for a governed write, evaluated for the requesting user, not the
 * running user. An approved request is executed later by a background job, so the checks must be
 * answered for whoever asked, and they are re-run at execution time because permissions and
 * sharing can change while a request waits for approval.
 *
 * An OpenBox ALLOW never overrides a failure here: both systems must agree before data changes.
 *
 * Field access: agent users hold guarded fields read-only on purpose, so no generic record action
 * can change them. The right to request a governed write is a custom permission (by default
 * OpenBox_Governed_Record_Write) that only the governed path honours; read access to every changed
 * field is still required.
 *
 * Runs without sharing because it inspects setup objects and other users' record access, which the
 * requesting user may not be able to see. It returns decisions only, never data.
 */
public without sharing class OpenBoxAccess {
    /** The entitlement a governed record write requires unless its writer names another. */
    public static final String DEFAULT_PERMISSION = 'OpenBox_Governed_Record_Write';

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

    /** Whether the user is active and holds the custom permission (none required when blank). */
    public static Decision canRequest(Id userId, String permission) {
        if (!isActive(userId)) {
            return deny('The requesting user is inactive');
        }
        if (String.isNotBlank(permission) && !holdsCustomPermission(userId, permission)) {
            return deny('The requesting user lacks the ' + permission + ' permission');
        }
        return allow();
    }

    /**
     * Whether the user may have the fields of the record changed for them: entitlement, edit
     * access to the object, read access to every field, and edit access to the record itself.
     */
    public static Decision canWrite(Id userId, String permission, SObjectType objectType, Set<String> fields, Id recordId) {
        Decision entitlement = canRequest(userId, permission);
        if (!entitlement.allowed) {
            return entitlement;
        }
        String objectName = objectType.getDescribe().getName();
        Set<Id> permissionSetIds = permissionSetsOf(userId);
        if (!objectEditable(permissionSetIds, objectName)) {
            return deny('The requesting user cannot edit ' + objectName + ' records');
        }
        for (String field : fields) {
            if (!fieldReadable(permissionSetIds, objectType, field)) {
                return deny('The requesting user cannot read ' + objectName + '.' + field);
            }
        }
        if (!recordEditable(userId, recordId)) {
            return deny('The requesting user has no edit access to this ' + objectType.getDescribe().getLabel());
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

    private static Boolean objectEditable(Set<Id> permissionSetIds, String objectName) {
        return [
                SELECT COUNT()
                FROM ObjectPermissions
                WHERE SobjectType = :objectName AND PermissionsEdit = TRUE AND ParentId IN :permissionSetIds
            ] > 0;
    }

    private static Boolean fieldReadable(Set<Id> permissionSetIds, SObjectType objectType, String field) {
        DescribeFieldResult describe = objectType.getDescribe().fields.getMap().get(field)?.getDescribe();
        if (describe == null) {
            return false;
        }
        if (!describe.isPermissionable()) {
            // Fields without field-level security (required and system fields) are readable by
            // anyone who can read the object.
            return true;
        }
        String objectName = objectType.getDescribe().getName();
        String qualifiedName = objectName + '.' + describe.getName();
        return [
                SELECT COUNT()
                FROM FieldPermissions
                WHERE
                    SobjectType = :objectName
                    AND Field = :qualifiedName
                    AND PermissionsRead = TRUE
                    AND ParentId IN :permissionSetIds
            ] > 0;
    }

    private static Boolean recordEditable(Id userId, Id recordId) {
        List<UserRecordAccess> access = [
            SELECT RecordId, HasEditAccess
            FROM UserRecordAccess
            WHERE UserId = :userId AND RecordId = :recordId
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
