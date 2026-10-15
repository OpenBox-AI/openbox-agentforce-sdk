/**
 * Agentforce action: governs the user's message before the agent reasons about it.
 *
 * Run it deterministically at the start of every subagent (Agent Script before_reasoning), with
 * the raw message and the conversation key the agent keeps in a variable. On the first message it
 * starts the conversation's OpenBox session and returns a new key; store it and pass it back on
 * every later call. When Allowed is false the agent must not act on the message: transition to a
 * subagent that relays Message and does nothing else.
 */
public with sharing class OpenBox_GovernMessage {
    public class Request {
        @InvocableVariable(
            label='User Message'
            description='The user\'s latest message, verbatim (Agent Script: @system_variables.user_input).'
        )
        public String userInput;

        @InvocableVariable(
            label='Conversation Key'
            description='The key returned by the first call of this conversation. Leave blank on the first message.'
        )
        public String conversationKey;

        @InvocableVariable(label='Subagent' description='The subagent handling the message.')
        public String subagent;
    }

    public class Result {
        @InvocableVariable(label='Allowed' description='True when OpenBox allows the agent to act on the message.')
        public Boolean allowed;

        @InvocableVariable(label='Conversation Key' description='Keep this and pass it to every later OpenBox action.')
        public String conversationKey;

        @InvocableVariable(label='Verdict' description='ALLOW, BLOCK, REQUIRE_APPROVAL, HALT, or ERROR.')
        public String verdict;

        @InvocableVariable(label='Reason' description='Why OpenBox refused the message, when it did.')
        public String reason;

        @InvocableVariable(label='Message' description='What to tell the user when the message was refused.')
        public String message;
    }

    @InvocableMethod(
        label='Govern User Message (OpenBox)'
        description='Checks the user\'s message with OpenBox before the agent acts on it. Run before reasoning on every turn.'
        category='OpenBox Governance'
    )
    public static List<Result> govern(List<Request> requests) {
        OpenBoxTurnGovernance governance = new OpenBoxTurnGovernance();
        List<Result> results = new List<Result>();
        for (Request request : requests) {
            OpenBoxTurnGovernance.Turn turn = new OpenBoxTurnGovernance.Turn();
            turn.userInput = request.userInput;
            turn.sessionKey = request.conversationKey;
            turn.subagent = request.subagent;
            OpenBoxTurnGovernance.Outcome outcome = governance.govern(turn);
            Result result = new Result();
            result.allowed = outcome.allowed;
            result.conversationKey = outcome.sessionKey;
            result.verdict = outcome.verdict;
            result.reason = outcome.reason;
            result.message = outcome.message;
            results.add(result);
        }
        return results;
    }
}
