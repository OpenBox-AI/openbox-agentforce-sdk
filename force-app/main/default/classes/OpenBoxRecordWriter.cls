/**
 * A change to one Salesforce record that an agent can request, governed by OpenBox end to end.
 * Extend it, describe the record and the change, and hand an instance to OpenBoxToolGovernance in
 * a ToolCall (call.writer). The SDK then does the rest, in this order:
 *
 *   1. validate() and the requesting user's entitlement (requiredPermission()); nothing is sent
 *      to OpenBox for an invalid or unentitled request
 *   2. a lookup activity (lookupActivityType()): the record is read as the requesting user
 *      (WITH USER_MODE) and reported with a SELECT span; the snapshot() is the activity output, so
 *      OpenBox output guardrails can redact it before summary() is shown to the agent
 *   3. the write activity (the tool name): ActivityStarted carries facts(), which is what OpenBox
 *      policies and input guardrails decide on. ALLOW goes on; REQUIRE_APPROVAL waits for a human
 *      in a later transaction; BLOCK and HALT end it with nothing written
 *   4. before writing: a locked re-read (SELECT ... FOR UPDATE span), a staleness check against
 *      what was read in step 2, refusal() for business rules, and Salesforce access for the
 *      requesting user (object edit, field read, record edit); then an UPDATE span whose started
 *      stage behaviour rules evaluate
 *   5. one system-mode update in the commit phase, with the changed fields authorized for that
 *      DML only (see OpenBoxFieldGuard), and the outcome reported to OpenBox through the outbox
 *
 * A writer must have a public no-argument constructor: an approved request is resumed from its
 * class name, possibly by a background job running as another user.
 */
public abstract class OpenBoxRecordWriter {
    /** The object whose records this writer changes. */
    public abstract SObjectType objectType();

    /** The record a call targets, from the tool input. Null or of another object is invalid. */
    public abstract Id recordId(Map<String, Object> input);

    /**
     * The change, as field API name to new value, typed as the field expects. Only these fields
     * are written, and only they are authorized past the field guard.
     */
    public abstract Map<String, Object> changes(Map<String, Object> input);

    /** The fields read for the decision, in order. Changed fields are always read as well. */
    public abstract List<String> snapshotFields();

    /** Why the input is invalid, or null. Checked before OpenBox is contacted. */
    public virtual String validate(Map<String, Object> input) {
        return null;
    }

    /** The custom permission the requesting user must hold; blank for none. */
    public virtual String requiredPermission() {
        return OpenBoxAccess.DEFAULT_PERMISSION;
    }

    /** How the change is named in messages, for example "discount change". */
    public virtual String changeLabel() {
        return objectType().getDescribe().getLabel().toLowerCase() + ' change';
    }

    /** The activity type of the read that precedes the write. */
    public virtual String lookupActivityType() {
        return objectName() + 'Lookup';
    }

    /** The lookup's ActivityStarted input (request_id and salesforce_org_id are added). */
    public virtual Map<String, Object> lookupInput(Id recordId) {
        return new Map<String, Object>{ 'object' => objectName(), 'record_id' => recordId, 'fields' => readFields() };
    }

    /** The lookup's output: what OpenBox output guardrails see, keyed by lower-case field name. */
    public virtual Map<String, Object> snapshot(SObject current) {
        Map<String, Object> snapshot = new Map<String, Object>{ 'record_id' => current.Id };
        for (String field : snapshotFields()) {
            snapshot.put(field.toLowerCase(), current.get(field));
        }
        return snapshot;
    }

    /**
     * The write's ActivityStarted input: the facts OpenBox policies decide on. request_id, action,
     * salesforce_org_id, requested_change, justification and actor_id are added by the SDK.
     */
    public virtual Map<String, Object> facts(SObject current, Map<String, Object> input) {
        Map<String, Object> facts = snapshot(current);
        facts.put('object', objectName());
        return facts;
    }

    /**
     * What the agent may be told about the record, built from the snapshot after OpenBox output
     * guardrails redacted it. Null for nothing.
     */
    public virtual String summary(SObject current, Map<String, Object> redactedSnapshot) {
        return null;
    }

    /** A business rule checked on the locked re-read just before writing: why not, or null. */
    public virtual String refusal(SObject current, Map<String, Object> input) {
        return null;
    }

    /** Extra attributes of the UPDATE span, for behaviour rules to match on. */
    public virtual Map<String, Object> writeAttributes(SObject current, Map<String, Object> changes) {
        return new Map<String, Object>();
    }

    /** The write activity's output once the change is made. */
    public virtual Map<String, Object> output(SObject before, Map<String, Object> changes) {
        Map<String, Object> previous = new Map<String, Object>();
        for (String field : changes.keySet()) {
            previous.put(field, before.get(field));
        }
        return new Map<String, Object>{
            'status' => 'executed',
            'record_id' => before.Id,
            'previous' => previous,
            'changes' => changes
        };
    }

    /** What the agent tells the user once the change is made. */
    public virtual String successMessage(SObject before, Map<String, Object> changes) {
        return 'The ' + changeLabel() + ' was applied.';
    }

    /** Every field the SDK reads: Id, the snapshot fields, the changed fields and SystemModstamp. */
    public List<String> readFields(Set<String> changedFields) {
        List<String> fields = new List<String>{ 'Id' };
        Set<String> seen = new Set<String>{ 'id', 'systemmodstamp' };
        List<String> wanted = new List<String>(snapshotFields());
        wanted.addAll(changedFields);
        for (String field : wanted) {
            if (seen.add(field.toLowerCase())) {
                fields.add(field);
            }
        }
        fields.add('SystemModstamp');
        return fields;
    }

    protected List<String> readFields() {
        return readFields(new Set<String>());
    }

    protected String objectName() {
        return objectType().getDescribe().getName();
    }
}
