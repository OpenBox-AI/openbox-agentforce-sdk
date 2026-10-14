// Registers the Agentforce agent on OpenBox (the environment configured in .env) and attaches its controls.
//
//   node scripts/openbox/provision.mjs          create whatever is missing
//   node scripts/openbox/provision.mjs --show   report what exists, change nothing
//   node scripts/openbox/provision.mjs --reset-policy   also restore dashboard-edited policy rules
//
// Everything is created once and then belongs to the OpenBox dashboard: existing policy rules,
// guardrails and behaviour rules are never overwritten, so they can be edited there freely.
//
// The agent's runtime key is returned once, at creation. It is written straight to .env and never
// printed. The agent proves its identity with the Salesforce workload certificate (see below).

import { basename } from 'node:path';
import { ENV_PATH, loadEnv, requireEnv, saveEnv } from '../lib/env.mjs';
import { OpenBoxPlatform, PlatformError } from '../lib/openbox-platform.mjs';
import {
  AGENT_NAME,
  AIVSS_CONFIG,
  BEHAVIOR_RULES,
  GOAL_ALIGNMENT,
  GUARDRAILS,
  POLICY_RULES,
} from './controls.mjs';

loadEnv();
const showOnly = process.argv.includes('--show');
const resetPolicy = process.argv.includes('--reset-policy');
const platform = new OpenBoxPlatform({
  apiKey: requireEnv('OPENBOX_ORG_API_KEY'),
  baseUrl: process.env.OPENBOX_PLATFORM_API_URL,
});

// The agent authenticates to Core through a Keycloak service account that trusts one RSA public
// key. The key pair lives in a Salesforce certificate (scripts/salesforce/workload-certificate.mjs);
// only its public JWK is sent to OpenBox.
function workloadPublicJwk() {
  const jwk = JSON.parse(requireEnv('OPENBOX_WORKLOAD_PUBLIC_JWK'));
  if (jwk.kty !== 'RSA' || jwk.alg !== 'RS256' || !jwk.kid || !jwk.n || !jwk.e || jwk.d) {
    throw new Error('OPENBOX_WORKLOAD_PUBLIC_JWK must be a public RS256 JWK; run scripts/salesforce/workload-certificate.mjs');
  }
  return jwk;
}

async function ensureAgent() {
  const existing = await platform.findAgent(AGENT_NAME);
  if (existing) {
    console.log(`agent      exists   ${existing.id}`);
    saveEnv({ OPENBOX_AGENT_ID: existing.id });
    return existing;
  }
  if (showOnly) {
    console.log('agent      missing');
    return null;
  }
  const publicJwk = workloadPublicJwk();
  const created = await platform.createAgent({
    agent_name: AGENT_NAME,
    agent_type: 'salesforce-agentforce',
    icon: 'briefcase',
    description:
      'Salesforce Agentforce sales agent. Opportunity discount changes are governed by OpenBox through a native Apex action.',
    tags: ['salesforce', 'agentforce', 'integration'],
    aivss_config: AIVSS_CONFIG,
    identity_verification: {
      method: 'keycloak_workload',
      mode: 'generate',
      source_type: 'openbox',
      public_jwk: publicJwk,
    },
  });
  const agent = created.agent ?? created;
  saveEnv({ OPENBOX_AGENT_ID: agent.id, OPENBOX_AGENT_API_KEY: created.token });
  console.log(`agent      created  ${agent.id} (workload identity, key ${publicJwk.kid})`);
  console.log(`           runtime key saved to ${basename(ENV_PATH)} (not printed)`);
  return agent;
}

const POLICY_RULE_FIELDS = ['priority', 'match_mode', 'conditions', 'decision', 'reason', 'description'];

function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.keys(value).sort().map((key) => [key, canonical(value[key])]));
  }
  return value ?? null;
}

function policyRuleChanged(current, wanted) {
  return POLICY_RULE_FIELDS.some(
    (key) => JSON.stringify(canonical(current[key])) !== JSON.stringify(canonical(wanted[key])),
  );
}

// Policy rules are created once and then owned by the OpenBox dashboard: a rule that already exists
// is never changed here, so edits made in the dashboard survive re-running this script. A rule that
// differs from the shipped default is reported; --reset-policy restores the defaults explicitly.
async function ensurePolicyRules(agentId) {
  const existing = new Map((await platform.listPolicyRules(agentId)).map((rule) => [rule.rule_name, rule]));
  for (const rule of POLICY_RULES) {
    const current = existing.get(rule.rule_name);
    if (!current) {
      if (showOnly) {
        console.log(`policy     missing  ${rule.rule_name}`);
        continue;
      }
      const created = await platform.createPolicyRule(agentId, rule);
      console.log(`policy     created  ${rule.rule_name} (${created.id})`);
    } else if (!policyRuleChanged(current, rule)) {
      console.log(`policy     exists   ${rule.rule_name}`);
    } else if (resetPolicy && !showOnly) {
      await platform.updatePolicyRule(agentId, current.id, { ...rule, change_log: 'Reset to the shipped default' });
      console.log(`policy     reset    ${rule.rule_name}`);
    } else {
      console.log(`policy     edited   ${rule.rule_name} (changed in the dashboard; kept)`);
    }
  }
}

async function ensureGuardrails(agentId) {
  const existing = new Set((await platform.listGuardrails(agentId)).map((guardrail) => guardrail.name));
  for (const guardrail of GUARDRAILS) {
    if (existing.has(guardrail.name)) {
      console.log(`guardrail  exists   ${guardrail.name}`);
    } else if (showOnly) {
      console.log(`guardrail  missing  ${guardrail.name}`);
    } else {
      const created = await platform.createGuardrail(agentId, guardrail);
      console.log(`guardrail  created  ${guardrail.name} (${created.id})`);
    }
  }
}

async function ensureBehaviorRules(agentId) {
  const existing = new Set((await platform.listBehaviorRules(agentId)).map((rule) => rule.rule_name));
  for (const rule of BEHAVIOR_RULES) {
    if (existing.has(rule.rule_name)) {
      console.log(`behaviour  exists   ${rule.rule_name}`);
    } else if (showOnly) {
      console.log(`behaviour  missing  ${rule.rule_name}`);
    } else {
      const created = await platform.createBehaviorRule(agentId, rule);
      console.log(`behaviour  created  ${rule.rule_name} (${created.id})`);
    }
  }
}

async function ensureGoalAlignment(agent) {
  const current = (await platform.getAgent(agent.id)).goal_alignment_config;
  if (current) {
    console.log(
      `goal       configured threshold=${current.alignment_threshold} action=${current.drift_detection_action}`,
    );
  } else if (showOnly) {
    console.log('goal       not configured');
  } else {
    await platform.setGoalAlignment(agent.id, GOAL_ALIGNMENT);
    console.log(`goal       enabled  threshold=${GOAL_ALIGNMENT.alignment_threshold}`);
  }
}

try {
  const agent = await ensureAgent();
  if (agent) {
    await ensurePolicyRules(agent.id);
    await ensureGuardrails(agent.id);
    await ensureBehaviorRules(agent.id);
    await ensureGoalAlignment(agent);
  }
} catch (error) {
  console.error(error instanceof PlatformError ? error.message : error);
  process.exitCode = 1;
}
