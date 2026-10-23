/**
 * Agentforce action: closes the turn's OpenBox run once the agent has replied.
 *
 * Run it deterministically at the end of every subagent (Agent Script after_reasoning) with the
 * conversation key. It sends WorkflowCompleted for the turn, so each user message is one complete
 * OpenBox run, unless a call of the turn is still waiting for human approval, in which case the
 * run is closed when that call is resolved. The next message starts a new run.
 */
public with sharing class OpenBox_EndTurn {
    public class Request {
        @InvocableVariable(label='Conversation Key' description='The key returned by Govern User Message.')
        public String conversationKey;
    }

    public class Result {
        @InvocableVariable(label='Closed' description='True when the turn\'s OpenBox run was closed now.')
        public Boolean closed;
    }

    @InvocableMethod(
        label='End Turn (OpenBox)'
        description='Closes the OpenBox run of the current turn after the agent has replied. Run after reasoning on every turn.'
        category='OpenBox Governance'
    )
    public static List<Result> endTurn(List<Request> requests) {
        OpenBoxTurnGovernance governance = new OpenBoxTurnGovernance();
        List<Result> results = new List<Result>();
        for (Request request : requests) {
            Result result = new Result();
            result.closed = String.isNotBlank(request.conversationKey) && governance.endTurn(request.conversationKey);
            results.add(result);
        }
        return results;
    }
}
