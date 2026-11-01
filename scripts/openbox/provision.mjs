// Registers the Agentforce agent on OpenBox (the environment configured in .env) and attaches its controls.
//
//   node scripts/openbox/provision.mjs          create whatever is missing
//   node scripts/openbox/provision.mjs --show   report what exists, change nothing
//   node scripts/openbox/provision.mjs --reset-policy   also restore dashboard-edited policy rules
//
// Everything is created once and then belongs to the OpenBox dashboard: existing policy rules,
// guardrails and behaviour rules are never overwritten, so they can be edited there freely. On an
// org that uses the governance control library, rules live once in the library and are attached
// to the agent; one already in the library under the shipped name is reused, not duplicated.
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

// Orgs on the governance control library (cutover state `final`) hold every rule once, in the
// library, and agents attach them. A shipped control is looked up by name and created only when
// the org has none, so a control already edited in the dashboard, or shared with other agents, is
// reused as it is. Editing one (--reset-policy) changes it for every agent that holds it.
const LIBRARY_KINDS = [
  { kind: 'policy_rule', label: 'policy', nameKey: 'rule_name', controls: POLICY_RULES },
  { kind: 'guardrail', label: 'guardrail', nameKey: 'name', controls: GUARDRAILS },
  { kind: 'behavior_rule', label: 'behaviour', nameKey: 'rule_name', controls: BEHAVIOR_RULES },
];

// The library assigns priorities itself and appends a new control at the bottom of its kind, so
// missing controls are created highest shipped priority first to land in the shipped order.
const byShippedPriority = (a, b) => (b.priority ?? 0) - (a.priority ?? 0);

async function ensureLibraryControls(agentId) {
  const attached = new Set(
    (await platform.directControls(agentId))
      .filter((link) => link.desiredState === 'attached')
      .map((link) => link.control?.id),
  );
  const held = new Map();
  for (const { kind, label, nameKey, controls } of LIBRARY_KINDS) {
    const ordered = kind === 'guardrail' ? controls : [...controls].sort(byShippedPriority);
    for (const wanted of ordered) {
      const name = wanted[nameKey];
      let control = await platform.findControl(kind, name);
      if (!control) {
        if (showOnly) {
          console.log(`${label.padEnd(10)} missing  ${name}`);
          continue;
        }
        const { priority, order, ...body } = wanted;
        control = await platform.createControl(kind, body, 'Shipped default (OpenBox for Salesforce Agentforce)');
        console.log(`${label.padEnd(10)} created  ${name} (${control.id})`);
      } else if (kind === 'policy_rule' && policyRuleChanged({ ...control.body, priority: wanted.priority }, wanted)) {
        const holders = control.usage?.effectiveAgents ?? 0;
        if (resetPolicy && !showOnly) {
          const { priority, order, ...body } = wanted;
          await platform.updateControl(control.id, body, 'Reset to the shipped default', control.currentVersion?.id);
          console.log(`${label.padEnd(10)} reset    ${name} (shared control: affects ${holders} agent(s))`);
        } else {
          console.log(`${label.padEnd(10)} edited   ${name} (changed in the control library; kept)`);
        }
      } else {
        console.log(`${label.padEnd(10)} exists   ${name}`);
      }
      held.set(`${kind}:${name}`, control);
      await attach(agentId, label, name, control.id, attached);
    }
  }
  await reportOrder(held);
}

async function attach(agentId, label, name, controlId, attached) {
  if (attached.has(controlId)) {
    console.log(`${label.padEnd(10)} attached ${name}`);
  } else if (showOnly) {
    console.log(`${label.padEnd(10)} detached ${name}`);
  } else {
    try {
      const link = await platform.attachControl(agentId, controlId);
      console.log(`${label.padEnd(10)} attach   ${name} (${link?.applyStatus ?? 'requested'})`);
    } catch (error) {
      if (error instanceof PlatformError && error.code === 'GOVERNANCE_CONTROL_ALREADY_INHERITED') {
        console.log(`${label.padEnd(10)} inherited ${name} (held through an agent role)`);
      } else {
        throw error;
      }
    }
  }
}

// Policy and behaviour rules are evaluated highest priority first; the first matching policy rule
// decides. The shipped rules depend on that order (HALT before BLOCK before REQUIRE_APPROVAL), so a
// library in which they sit in another order is reported. Shared controls are never reordered here.
async function reportOrder(held) {
  for (const { kind, label, nameKey, controls } of LIBRARY_KINDS) {
    if (kind === 'guardrail') continue;
    const shipped = [...controls].sort(byShippedPriority).map((control) => control[nameKey]);
    const current = [];
    for (const name of shipped) {
      const control = held.has(`${kind}:${name}`) ? await platform.findControl(kind, name) : null;
      if (control) current.push({ name, priority: control.priority ?? control.body?.priority ?? 0 });
    }
    const evaluated = [...current].sort((a, b) => b.priority - a.priority).map((control) => control.name);
    const expected = shipped.filter((name) => evaluated.includes(name));
    if (evaluated.join('\n') === expected.join('\n')) {
      console.log(`${label.padEnd(10)} order    as shipped`);
    } else {
      console.log(`${label.padEnd(10)} ORDER    differs from the shipped order; reorder in the OpenBox control library:`);
      expected.forEach((name, i) => console.log(`             ${i + 1}. ${name}`));
      process.exitCode = 1;
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
    if (await platform.controlLibraryEnabled()) {
      await ensureLibraryControls(agent.id);
    } else {
      await ensurePolicyRules(agent.id);
      await ensureGuardrails(agent.id);
      await ensureBehaviorRules(agent.id);
    }
    await ensureGoalAlignment(agent);
  }
} catch (error) {
  console.error(error instanceof PlatformError ? error.message : error);
  process.exitCode = 1;
}
