/**
 * Agentforce action: runs a registered tool (a flow, standard action or invocable Apex class)
 * under OpenBox governance.
 *
 * This is how an agent reaches anything that is not itself an OpenBox-governed Apex action. The
 * agent names a tool and passes its arguments as JSON; only tools registered and active in
 * OpenBox_Governed_Tool__mdt can run, so the model can never reach an arbitrary flow or action.
 * OpenBox decides before the tool runs, exactly as for every other governed tool call.
 */
public with sharing class OpenBox_GovernedAction {
    public class Request {
        @InvocableVariable(
            label='Tool Name'
            description='The registered tool to run, for example log_opportunity_note.'
            required=true
        )
        public String toolName;

        @InvocableVariable(
            label='Tool Input (JSON)'
            description='The tool arguments as a JSON object, for example {"opportunityId":"006...","subject":"Call"}.'
        )
        public String inputJson;

        @InvocableVariable(label='Conversation Key' description='The conversation key returned by Govern User Message.')
        public String conversationKey;
    }

    public class Result {
        @InvocableVariable(
            label='Status'
            description='Executed, Pending_Approval, Approved, Blocked, Halted, Failed or Not_Registered.'
        )
        public String status;

        @InvocableVariable(label='Executed' description='True only when the tool actually ran.')
        public Boolean executed;

        @InvocableVariable(label='Message' description='Plain-language outcome to relay to the user.')
        public String message;

        @InvocableVariable(label='Output (JSON)' description='The tool result as JSON, when it ran.')
        public String outputJson;

        @InvocableVariable(label='Verdict' description='OpenBox verdict: ALLOW, REQUIRE_APPROVAL, BLOCK, HALT or ERROR.')
        public String verdict;

        @InvocableVariable(label='Reason' description='Why OpenBox or Salesforce reached this outcome.')
        public String reason;

        @InvocableVariable(label='Request Number' description='Governed request reference, for checking on an approval.')
        public String requestNumber;

        @InvocableVariable(label='Conversation Key' description='The conversation key, unchanged or newly started.')
        public String conversationKey;
    }

    @InvocableMethod(
        label='Run Governed Tool (OpenBox)'
        description='Runs a registered tool after OpenBox authorizes it. Relay the message to the user and never claim a tool ran unless Executed is true.'
        category='OpenBox Governance'
    )
    public static List<Result> run(List<Request> requests) {
        Map<String, OpenBox_Governed_Tool__mdt> registry = new Map<String, OpenBox_Governed_Tool__mdt>();
        for (OpenBox_Governed_Tool__mdt tool : OpenBox_Governed_Tool__mdt.getAll().values()) {
            if (tool.Active__c && String.isNotBlank(tool.Tool_Name__c)) {
                registry.put(tool.Tool_Name__c.trim().toLowerCase(), tool);
            }
        }
        // Every registered call is decided before any of them runs, so they share one transaction.
        List<Result> results = new List<Result>();
        List<OpenBoxToolGovernance.ToolCall> calls = new List<OpenBoxToolGovernance.ToolCall>();
        List<Integer> positions = new List<Integer>();
        for (Request request : requests) {
            Object prepared = prepare(registry, request);
            if (prepared instanceof Result) {
                results.add((Result) prepared);
            } else {
                results.add(null);
                calls.add((OpenBoxToolGovernance.ToolCall) prepared);
                positions.add(results.size() - 1);
            }
        }
        if (!calls.isEmpty()) {
            List<OpenBoxToolGovernance.Result> outcomes = new OpenBoxToolGovernance().governAll(calls);
            for (Integer i = 0; i < outcomes.size(); i++) {
                results[positions[i]] = toResult(outcomes[i]);
            }
        }
        return results;
    }

    /** The tool call for a request, or the refusal when it names no registered tool or bad input. */
    private static Object prepare(Map<String, OpenBox_Governed_Tool__mdt> registry, Request request) {
        String name = request.toolName == null ? '' : request.toolName.trim().toLowerCase();
        OpenBox_Governed_Tool__mdt tool = registry.get(name);
        if (tool == null) {
            return refusal('Not_Registered', 'No governed tool named "' + request.toolName + '" is available.', request);
        }
        Map<String, Object> input;
        try {
            Object parsed = String.isBlank(request.inputJson) ? new Map<String, Object>() : JSON.deserializeUntyped(request.inputJson);
            if (!(parsed instanceof Map<String, Object>)) {
                return refusal('Failed', 'Tool Input must be a JSON object.', request);
            }
            input = (Map<String, Object>) parsed;
        } catch (JSONException e) {
            return refusal('Failed', 'Tool Input is not valid JSON: ' + e.getMessage(), request);
        }

        OpenBoxToolGovernance.ToolCall call = new OpenBoxToolGovernance.ToolCall();
        call.sessionKey = request.conversationKey;
        call.toolName = tool.Tool_Name__c.trim();
        call.input = input;
        call.targetType = tool.Target_Type__c == null ? null : tool.Target_Type__c.trim().toLowerCase();
        call.targetName = tool.Target_Name__c == null ? null : tool.Target_Name__c.trim();
        call.readOnly = tool.Read_Only__c;
        call.justification = input.get('justification') instanceof String ? (String) input.get('justification') : null;
        if (call.targetType == OpenBoxToolGovernance.TARGET_RECORD_WRITER) {
            Type writer = String.isBlank(call.targetName) ? null : Type.forName(call.targetName);
            if (writer == null) {
                return refusal('Failed', 'The record writer ' + call.targetName + ' of tool ' + call.toolName + ' does not exist.', request);
            }
            call.writer = writer;
        }
        return call;
    }

    public static Result toResult(OpenBoxToolGovernance.Result outcome) {
        Result result = new Result();
        result.status = outcome.status;
        result.executed = outcome.executed;
        result.message = outcome.message;
        result.outputJson = outcome.outputJson();
        result.verdict = outcome.verdict;
        result.reason = outcome.reason;
        result.requestNumber = outcome.requestNumber;
        result.conversationKey = outcome.sessionKey;
        return result;
    }

    private static Result refusal(String status, String message, Request request) {
        Result result = new Result();
        result.status = status;
        result.executed = false;
        result.message = message;
        result.conversationKey = request.conversationKey;
        return result;
    }
}
