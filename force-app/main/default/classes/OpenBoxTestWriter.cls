/**
 * A governed record write for the SDK's own tests: changes Opportunity.NextStep. Closed
 * Opportunities are refused as a business rule, and the description is what output guardrails
 * redact before the agent sees it.
 */
@IsTest
public class OpenBoxTestWriter extends OpenBoxRecordWriter {
    public static final String TOOL_NAME = 'OpportunityNextStepUpdate';
    public static final String LOOKUP = 'OpportunityLookup';

    public override SObjectType objectType() {
        return Opportunity.SObjectType;
    }

    public override Id recordId(Map<String, Object> input) {
        Object value = input.get('record_id');
        return value == null ? null : Id.valueOf(String.valueOf(value));
    }

    public override Map<String, Object> changes(Map<String, Object> input) {
        return new Map<String, Object>{ 'NextStep' => input.get('next_step') };
    }

    public override List<String> snapshotFields() {
        return new List<String>{ 'Name', 'StageName', 'IsClosed', 'NextStep', 'Description' };
    }

    public override String validate(Map<String, Object> input) {
        return String.isBlank((String) input.get('next_step')) ? 'next_step is required' : null;
    }

    public override String summary(SObject current, Map<String, Object> redactedSnapshot) {
        return current.get('Name') + ' | ' + redactedSnapshot.get('description');
    }

    public override String refusal(SObject current, Map<String, Object> input) {
        return ((Opportunity) current).IsClosed ? 'Closed Opportunities are not changed' : null;
    }

    public override Map<String, Object> writeAttributes(SObject current, Map<String, Object> changes) {
        return new Map<String, Object>{ 'salesforce.opportunity.stage' => current.get('StageName') };
    }

    public static OpenBoxToolGovernance.ToolCall call(Id recordId, String nextStep) {
        OpenBoxToolGovernance.ToolCall call = new OpenBoxToolGovernance.ToolCall();
        call.toolName = TOOL_NAME;
        call.writer = OpenBoxTestWriter.class;
        call.input = new Map<String, Object>{ 'record_id' => recordId, 'next_step' => nextStep };
        call.justification = 'Agreed on the last call';
        call.userPrompt = 'Set the next step to ' + nextStep;
        return call;
    }
}
