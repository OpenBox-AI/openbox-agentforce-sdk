/**
 * Reference implementation: an Opportunity discount change as an OpenBox governed record write.
 *
 * Everything that makes the change safe (the governed lookup, the OpenBox decision, the locked
 * re-read, the staleness and access checks, the behaviour-rule spans, approvals and the field
 * guard) comes from the OpenBox SDK. This class only says what is read, what changes, and which
 * facts OpenBox policies decide on. The events it produces:
 *
 *   ActivityStarted   OpportunityLookup                 read the record the agent wants to change
 *     span SELECT Opportunity        started -> completed
 *   ActivityCompleted OpportunityLookup                 output guardrails may redact the snapshot
 *   ActivityStarted   OpportunityDiscountUpdate         OpenBox policy + input guardrails decide
 *     span SELECT Opportunity (FOR UPDATE)  started -> completed     locked re-read
 *     span UPDATE Opportunity        started  (behaviour rules decide) -> write -> completed
 *   ActivityCompleted OpportunityDiscountUpdate
 */
public with sharing class OpportunityDiscountWriter extends OpenBoxRecordWriter {
    public static final String TOOL_NAME = 'OpportunityDiscountUpdate';
    public static final String ACTION = 'opportunity.update_discount';

    private static final Decimal MIN_DISCOUNT = 0;
    private static final Decimal MAX_DISCOUNT = 100;
    private static final Integer MAX_DECIMAL_PLACES = 2;

    public override SObjectType objectType() {
        return Opportunity.SObjectType;
    }

    public override Id recordId(Map<String, Object> input) {
        Object value = input.get('opportunity_id');
        try {
            return value == null ? null : Id.valueOf(String.valueOf(value));
        } catch (StringException e) {
            return null;
        }
    }

    public override Map<String, Object> changes(Map<String, Object> input) {
        return new Map<String, Object>{ 'Discount__c' => proposed(input) };
    }

    public override List<String> snapshotFields() {
        return new List<String>{ 'Name', 'StageName', 'Amount', 'IsClosed', 'Discount__c', 'Description' };
    }

    public override String validate(Map<String, Object> input) {
        Id opportunityId = recordId(input);
        if (opportunityId == null || opportunityId.getSobjectType() != Opportunity.SObjectType) {
            return 'opportunityId must be an Opportunity record id';
        }
        Decimal discount = proposed(input);
        if (discount == null) {
            return 'proposedDiscount is required';
        }
        if (discount < MIN_DISCOUNT || discount > MAX_DISCOUNT) {
            return 'proposedDiscount must be between ' + MIN_DISCOUNT + ' and ' + MAX_DISCOUNT + ' percent';
        }
        if (discount.setScale(MAX_DECIMAL_PLACES, RoundingMode.DOWN) != discount) {
            return 'proposedDiscount supports at most ' + MAX_DECIMAL_PLACES + ' decimal places';
        }
        return null;
    }

    public override String changeLabel() {
        return 'discount change';
    }

    public override Map<String, Object> lookupInput(Id recordId) {
        return new Map<String, Object>{ 'opportunity_id' => recordId, 'fields' => snapshotFields() };
    }

    public override Map<String, Object> snapshot(SObject current) {
        Opportunity record = (Opportunity) current;
        return new Map<String, Object>{
            'opportunity_id' => record.Id,
            'name' => record.Name,
            'stage_name' => record.StageName,
            'amount' => record.Amount,
            'is_closed' => record.IsClosed,
            'current_discount' => record.Discount__c,
            'description' => record.Description
        };
    }

    /** What the provisioned OpenBox policies read: is_closed and proposed_discount above all. */
    public override Map<String, Object> facts(SObject current, Map<String, Object> input) {
        Opportunity record = (Opportunity) current;
        Decimal previous = record.Discount__c == null ? 0 : record.Discount__c;
        Decimal proposed = proposed(input);
        return new Map<String, Object>{
            'opportunity_id' => record.Id,
            'opportunity_name' => record.Name,
            'stage_name' => record.StageName,
            'amount' => record.Amount,
            'is_closed' => record.IsClosed,
            'current_discount' => previous,
            'proposed_discount' => proposed,
            'discount_change' => proposed - previous
        };
    }

    public override String summary(SObject current, Map<String, Object> redactedSnapshot) {
        Opportunity record = (Opportunity) current;
        String summary = record.Name + ' | stage ' + record.StageName + ' | current discount ' + formatPercent(record.Discount__c);
        String description = (String) redactedSnapshot.get('description');
        return String.isBlank(description) ? summary : summary + ' | ' + description.abbreviate(500);
    }

    public override String refusal(SObject current, Map<String, Object> input) {
        return ((Opportunity) current).IsClosed ? 'Closed Opportunities cannot be discounted' : null;
    }

    /** The late-stage sign-off behaviour rule matches on the stage. */
    public override Map<String, Object> writeAttributes(SObject current, Map<String, Object> changes) {
        Opportunity record = (Opportunity) current;
        return new Map<String, Object>{
            'salesforce.opportunity.stage' => record.StageName,
            'salesforce.discount.previous' => record.Discount__c == null ? 0 : record.Discount__c,
            'salesforce.discount.proposed' => changes.get('Discount__c')
        };
    }

    public override Map<String, Object> output(SObject before, Map<String, Object> changes) {
        return new Map<String, Object>{
            'status' => 'executed',
            'opportunity_id' => before.Id,
            'previous_discount' => ((Opportunity) before).Discount__c,
            'new_discount' => changes.get('Discount__c')
        };
    }

    public override String successMessage(SObject before, Map<String, Object> changes) {
        Opportunity record = (Opportunity) before;
        return 'Discount on ' + record.Name + ' changed from ' + formatPercent(record.Discount__c) + ' to ' +
            formatPercent((Decimal) changes.get('Discount__c')) + '.';
    }

    /** The tool input of a discount request, as the agent action passes it. */
    public static Map<String, Object> input(Id opportunityId, Decimal proposedDiscount) {
        return new Map<String, Object>{ 'opportunity_id' => opportunityId, 'proposed_discount' => proposedDiscount };
    }

    public static String formatPercent(Decimal value) {
        return (value == null ? '0' : value.stripTrailingZeros().toPlainString()) + '%';
    }

    private static Decimal proposed(Map<String, Object> input) {
        Object value = input.get('proposed_discount');
        return value == null ? null : Decimal.valueOf(String.valueOf(value));
    }
}
