/**
 * Lifecycle of a governed request (OpenBox_Governed_Request__c.Status__c), shared by every governed
 * tool call and record write.
 *
 *   Authorizing -> Executed | Blocked | Halted | Permission_Denied | Failed
 *               -> Pending_Approval -> Approved -> Executed | Failed | Stale | Permission_Denied
 *                                   -> Rejected | Expired | Halted
 *
 * Only Pending_Approval and Approved are waiting; every other status after Authorizing is final.
 */
public inherited sharing class OpenBoxRequestStatus {
    public static final String AUTHORIZING = 'Authorizing';
    public static final String PENDING = 'Pending_Approval';
    public static final String APPROVED = 'Approved';
    public static final String EXECUTED = 'Executed';
    public static final String BLOCKED = 'Blocked';
    public static final String HALTED = 'Halted';
    public static final String REJECTED = 'Rejected';
    public static final String EXPIRED = 'Expired';
    public static final String STALE = 'Stale';
    public static final String PERMISSION_DENIED = 'Permission_Denied';
    public static final String FAILED = 'Failed';

    /** The statuses of a request still waiting for a human, or approved and not yet run. */
    public static final Set<String> WAITING = new Set<String>{ PENDING, APPROVED };

    private OpenBoxRequestStatus() {
    }

    public static Boolean isWaiting(String status) {
        return WAITING.contains(status);
    }
}
