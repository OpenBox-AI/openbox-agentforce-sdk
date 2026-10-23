/**
 * What a governed tool's executor knows about the call it is running.
 */
public inherited sharing class OpenBoxToolContext {
    /** The user the agent ran as when it asked for the call. Check access for this user. */
    public final Id requestedById;
    /** The conversation the call belongs to. */
    public final String sessionKey;
    /** Correlation id shared by Salesforce and OpenBox for this call. */
    public final String requestId;
    /** True when the call runs after a human approved it, in a later transaction. */
    public final Boolean resumedAfterApproval;

    public OpenBoxToolContext(Id requestedById, String sessionKey, String requestId, Boolean resumedAfterApproval) {
        this.requestedById = requestedById;
        this.sessionKey = sessionKey;
        this.requestId = requestId;
        this.resumedAfterApproval = resumedAfterApproval;
    }
}
