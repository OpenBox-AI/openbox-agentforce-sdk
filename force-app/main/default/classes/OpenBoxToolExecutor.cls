/**
 * The work behind a governed tool, written in Apex. OpenBoxToolGovernance calls execute() only
 * after OpenBox allows the call, or after a human approves it in OpenBox.
 *
 * An executor that is resumed after approval runs in a background job, as a different user than
 * the one who asked. It must therefore check access for context.requestedById itself, the way the
 * discount action does with OpenBoxAccess, and needs a public no-argument constructor so it can be
 * rebuilt by class name.
 *
 * Throwing from execute() reports the call as failed; any data the executor changed before
 * throwing is rolled back.
 */
public interface OpenBoxToolExecutor {
    Map<String, Object> execute(OpenBoxToolContext context, Map<String, Object> input);
}
