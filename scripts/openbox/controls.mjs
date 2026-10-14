// The OpenBox controls that govern the Agentforce discount action. Kept as data so the
// provisioning script and the live test suite assert against the same definitions.

// One OpenBox agent per Salesforce org: a second org (e.g. a package test org) sets its own name.
export const AGENT_NAME = process.env.OPENBOX_AGENT_NAME || 'Agentforce Sales Agent (Salesforce)';
export const ACTIVITY_LOOKUP = 'OpportunityLookup';
export const ACTIVITY_UPDATE = 'OpportunityDiscountUpdate';

// AIVSS risk profile required by OpenBox at agent registration (scales as in the OpenBox API):
// reachable over the network, needs a signed-in Salesforce user who starts the conversation,
// handles confidential commercial data and changes pricing, no availability or safety impact.
export const AIVSS_CONFIG = {
  base_security: { attack_vector: 1, attack_complexity: 1, privileges_required: 2, user_interaction: 2, scope: 1 },
  ai_specific: { model_robustness: 3, data_sensitivity: 3, ethical_impact: 2, decision_criticality: 3, adaptability: 2 },
  impact: { confidentiality_impact: 2, integrity_impact: 3, availability_impact: 1, safety_impact: 1 },
};

export const THRESHOLDS = { approvalAbove: 15, blockAbove: 40, haltAtOrAbove: 90 };

// Policy rules, evaluated highest priority first; the first rule whose conditions all match decides,
// and an event no rule matches is allowed. Rules read the request from activity_input, which only the
// plain ActivityStarted of the update carries: span hooks have no activity_input, so an approved
// request's later spans are never re-gated. (A "hook_trigger is not true" condition cannot express
// this: a missing field makes the comparison undefined in Rego and the rule would never match.)
const isUpdateDecision = [
  field('event_type', 'equals', 'ActivityStarted'),
  field('activity_type', 'equals', ACTIVITY_UPDATE),
];
const DISCOUNT = 'activity_input[0].proposed_discount';

export const POLICY_RULES = [
  {
    rule_name: 'Closed opportunities cannot be discounted',
    priority: 100,
    conditions: [...isUpdateDecision, field('activity_input[0].is_closed', 'equals', true, 'boolean')],
    decision: 'BLOCK',
    reason: 'Closed opportunities cannot be discounted',
  },
  {
    rule_name: `Discount of ${THRESHOLDS.haltAtOrAbove}% or more halts the agent`,
    priority: 90,
    conditions: [...isUpdateDecision, field(DISCOUNT, 'greater_than_or_equal', THRESHOLDS.haltAtOrAbove, 'number')],
    decision: 'HALT',
    reason: `A discount of ${THRESHOLDS.haltAtOrAbove}% or more is treated as abuse; the agent session is halted`,
  },
  {
    rule_name: `Discounts above ${THRESHOLDS.blockAbove}% are blocked`,
    priority: 80,
    conditions: [...isUpdateDecision, field(DISCOUNT, 'greater_than', THRESHOLDS.blockAbove, 'number')],
    decision: 'BLOCK',
    reason: `Discounts above ${THRESHOLDS.blockAbove}% are forbidden for agents`,
  },
  {
    rule_name: `Discounts above ${THRESHOLDS.approvalAbove}% need sales-ops approval`,
    priority: 70,
    conditions: [...isUpdateDecision, field(DISCOUNT, 'greater_than', THRESHOLDS.approvalAbove, 'number')],
    decision: 'REQUIRE_APPROVAL',
    reason: `Discounts above ${THRESHOLDS.approvalAbove}% require sales-ops approval`,
  },
].map((rule) => ({
  description: rule.reason,
  match_mode: 'all',
  constraints: [],
  trust_impact: 'none',
  trust_threshold: null,
  ...rule,
}));

function field(path, operator, value, valueType = 'string') {
  return {
    id: `condition-${path.replace(/\W+/g, '-')}`,
    left: { kind: 'field', field: `input.${path}`, transform: 'value', valueType },
    operator,
    right: { kind: 'literal', value: String(value), valueType },
  };
}

const updateInput = [{ activity_type: ACTIVITY_UPDATE, fields_to_check: ['input.*.justification'] }];
const lookupOutput = [{ activity_type: ACTIVITY_LOOKUP, fields_to_check: ['output.description'] }];

export const BANNED_PHRASES = [
  'ignore policy',
  'bypass approval',
  'override governance',
  'ignore previous instructions',
];

export const GUARDRAILS = [
  {
    guardrail_type: '1',
    name: 'Justification PII redaction',
    description: 'Mask personal data in the business justification before it is stored or shown',
    processing_stage: '0',
    params: { entities: ['EMAIL_ADDRESS', 'PHONE_NUMBER', 'US_SSN', 'CREDIT_CARD'] },
    settings: { on_fail: 0, activities: updateInput, log_violation: true },
  },
  {
    guardrail_type: '4',
    name: 'Justification manipulation tripwire',
    description: 'Refuse requests whose justification tries to talk the agent past governance',
    processing_stage: '0',
    params: { banned_words: BANNED_PHRASES },
    settings: { on_fail: 1, activities: updateInput, log_violation: true },
  },
  {
    guardrail_type: '1',
    name: 'Opportunity snapshot PII redaction',
    description: 'Mask personal data in the Opportunity description before the agent sees it',
    processing_stage: '1',
    params: { entities: ['EMAIL_ADDRESS', 'PHONE_NUMBER'] },
    settings: { on_fail: 0, activities: lookupOutput, log_violation: true },
  },
];

export const LATE_STAGE = 'Negotiation/Review';

export const BEHAVIOR_RULES = [
  {
    rule_name: 'Discount write requires a locked re-read',
    description:
      'An Opportunity discount may only be written right after the record was re-read under a row lock in the same activity.',
    priority: 90,
    trigger: 'database_update',
    trigger_match: [{ field: 'db_statement', op: 'contains', value: 'Discount__c' }],
    states: [
      { semantic_type: 'database_select', match: [{ field: 'db_statement', op: 'contains', value: 'FOR UPDATE' }] },
    ],
    time_window: 120,
    verdict: 3,
    reject_message: 'Discount write attempted without a fresh locked read of the record',
  },
  {
    rule_name: 'Late-stage discount needs sales-ops sign-off',
    description: `Discount changes on Opportunities in ${LATE_STAGE} require a sales-ops sign-off step before the write.`,
    priority: 80,
    trigger: 'database_update',
    trigger_match: [{ field: 'attributes.salesforce.opportunity.stage', op: 'eq', value: LATE_STAGE }],
    states: [{ semantic_type: 'internal', match: [{ field: 'name', op: 'eq', value: 'sales_ops.signoff' }] }],
    time_window: 3600,
    verdict: 2,
    approval_timeout: 1800,
    reject_message: `Discounts on ${LATE_STAGE} deals need sales-ops sign-off`,
  },
];

export const GOAL_ALIGNMENT = {
  alignment_threshold: 70,
  llama_firewall_model: 'gpt-4o-mini',
  drift_detection_action: 'alert_only',
  evaluation_frequency: 'every_action',
};
