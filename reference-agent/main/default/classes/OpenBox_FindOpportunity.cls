/**
 * Agentforce custom action: find Opportunities by name so the agent can resolve "the Acme deal" to
 * a record id before requesting a governed discount change. Read-only, and runs in user mode: the
 * agent sees only the records and fields its user may see. Discounts are reported, never changed.
 *
 * Inside a governed conversation (a conversation key is passed) the lookup is a governed tool call
 * like any other: OpenBox sees the search before it runs and can refuse it, and output guardrails
 * apply to the matches before the agent sees them.
 */
public with sharing class OpenBox_FindOpportunity {
    private static final Integer MAX_MATCHES = 5;

    public class Request {
        @InvocableVariable(
            label='Opportunity Name'
            description='All or part of the Opportunity name the user mentioned.'
            required=true
        )
        public String nameQuery;

        @InvocableVariable(label='Conversation Key' description='The conversation key returned by Govern User Message.')
        public String conversationKey;
    }

    public class Result {
        @InvocableVariable(label='Match Count' description='How many Opportunities matched.')
        public Integer matchCount;

        @InvocableVariable(
            label='Matches'
            description='One line per match: record id, name, stage and current discount. Ask the user to choose when there is more than one.'
        )
        public String matches;

        @InvocableVariable(label='Opportunity ID' description='The record id when exactly one Opportunity matched.')
        public Id opportunityId;
    }

    @InvocableMethod(
        label='Find Opportunity'
        description='Looks up Opportunities by name and returns their record ids, stages and current discounts. Use it to get the record id before changing a discount.'
        category='OpenBox Governance'
    )
    public static List<Result> find(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request request : requests) {
            results.add(String.isBlank(request.conversationKey) ? findOne(request.nameQuery) : findGoverned(request));
        }
        return results;
    }

    public static final String TOOL_NAME = 'find_opportunity';

    /** The lookup as a governed tool: OpenBox decides before it runs. */
    public class Finder implements OpenBoxToolExecutor {
        public Map<String, Object> execute(OpenBoxToolContext context, Map<String, Object> input) {
            Result found = findOne((String) input.get('name_query'));
            return new Map<String, Object>{
                'match_count' => found.matchCount,
                'matches' => found.matches,
                'opportunity_id' => found.opportunityId
            };
        }
    }

    private static Result findGoverned(Request request) {
        OpenBoxToolGovernance.ToolCall call = new OpenBoxToolGovernance.ToolCall();
        call.sessionKey = request.conversationKey;
        call.toolName = TOOL_NAME;
        call.input = new Map<String, Object>{ 'name_query' => request.nameQuery };
        call.targetType = OpenBoxToolGovernance.TARGET_APEX_EXECUTOR;
        call.targetName = Finder.class.getName();
        call.readOnly = true;
        OpenBoxToolGovernance.Result outcome = new OpenBoxToolGovernance().govern(call);

        Result result = new Result();
        if (!outcome.executed || outcome.output == null) {
            result.matchCount = 0;
            result.matches = outcome.message;
            return result;
        }
        Object count = outcome.output.get('match_count');
        Object recordId = outcome.output.get('opportunity_id');
        result.matchCount = count == null ? 0 : Integer.valueOf(count);
        result.matches = (String) outcome.output.get('matches');
        result.opportunityId = recordId == null ? null : Id.valueOf(String.valueOf(recordId));
        return result;
    }

    private static Result findOne(String nameQuery) {
        Result result = new Result();
        String term = nameQuery == null ? '' : nameQuery.trim();
        if (term.length() < 2) {
            result.matchCount = 0;
            result.matches = 'Provide at least two characters of the Opportunity name.';
            return result;
        }
        // A bind variable needs no quote escaping, but LIKE wildcards in user text must match literally.
        String pattern = '%' + term.replace('\\', '\\\\').replace('%', '\\%').replace('_', '\\_') + '%';
        List<Opportunity> found = [
            SELECT Id, Name, StageName, Discount__c
            FROM Opportunity
            WHERE Name LIKE :pattern
            WITH USER_MODE
            ORDER BY LastModifiedDate DESC
            LIMIT :MAX_MATCHES
        ];
        List<String> lines = new List<String>();
        for (Opportunity record : found) {
            Decimal discount = record.Discount__c == null ? 0 : record.Discount__c;
            lines.add(
                record.Id +
                    ' | ' +
                    record.Name +
                    ' | ' +
                    record.StageName +
                    ' | discount ' +
                    discount.stripTrailingZeros().toPlainString() +
                    '%'
            );
        }
        result.matchCount = found.size();
        result.matches = found.isEmpty() ? 'No Opportunity matches "' + term + '".' : String.join(lines, '\n');
        result.opportunityId = found.size() == 1 ? found[0].Id : null;
        return result;
    }
}