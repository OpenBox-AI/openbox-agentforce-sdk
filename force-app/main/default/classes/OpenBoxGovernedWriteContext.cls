/**
 * The record fields whose change OpenBox has authorized in the current transaction. A field guard
 * (OpenBoxFieldGuard, called from a trigger) rejects every other change to a guarded field, which
 * is what makes the governed write the only path an agent has to that field.
 *
 * Authorizations are scoped to a single DML call: callers authorize, write, and revoke in a
 * finally block, so an authorization can never leak to a later, ungoverned update.
 */
public inherited sharing class OpenBoxGovernedWriteContext {
    private static Map<Id, Set<String>> authorizedFields = new Map<Id, Set<String>>();

    private OpenBoxGovernedWriteContext() {
    }

    /** Authorizes changes to the given fields (API names, any case) of one record. */
    public static void authorize(Id recordId, Set<String> fields) {
        Set<String> granted = authorizedFields.get(recordId);
        if (granted == null) {
            granted = new Set<String>();
            authorizedFields.put(recordId, granted);
        }
        for (String field : fields) {
            granted.add(field.toLowerCase());
        }
    }

    public static void revokeAll() {
        authorizedFields.clear();
    }

    public static Boolean isAuthorized(Id recordId, String field) {
        Set<String> granted = authorizedFields.get(recordId);
        return granted != null && field != null && granted.contains(field.toLowerCase());
    }
}
