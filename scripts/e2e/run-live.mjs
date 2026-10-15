// Live end-to-end suite: the deployed Apex action in a Salesforce org against live OpenBox.
//
//   node scripts/e2e/run-live.mjs [--target-org <alias>] [--only <scenario,...>]
//
// Every scenario asserts three independent things:
//   1. Salesforce: the Opportunity value, the governed-request status and the audit trail;
//   2. OpenBox: the verdicts Core actually recorded for the run;
//   3. Protocol: the stored session pairs every Started with its Completed and every span's
//      started stage with its completed stage (read back from OpenBox, not from what was sent).
// A scenario passes only when all three hold. Results are written to out/e2e-report.json.

import { mkdirSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { setTimeout as sleep } from 'node:timers/promises';
import { PROJECT_ROOT, loadEnv, requireEnv } from '../lib/env.mjs';
import { OpenBoxPlatform } from '../lib/openbox-platform.mjs';
import { renderSession, verdictName, verifySession } from '../lib/session-verifier.mjs';
import { runApex, sfJson, targetOrgArgs } from '../lib/sf.mjs';
import { BANNED_PHRASES, THRESHOLDS } from '../openbox/controls.mjs';
import { AgentConversation } from '../lib/agent-conversation.mjs';

loadEnv();
const orgArgs = targetOrgArgs(process.argv);
const onlyIndex = process.argv.indexOf('--only');
const only = onlyIndex >= 0 ? new Set(process.argv[onlyIndex + 1].split(',')) : null;
const platform = new OpenBoxPlatform({ apiKey: requireEnv('OPENBOX_ORG_API_KEY'), baseUrl: process.env.OPENBOX_PLATFORM_API_URL });
const agentId = requireEnv('OPENBOX_AGENT_ID');

const OPP = {
  routine: 'OBX Demo - Routine Renewal',
  late: 'OBX Demo - Late Stage Expansion',
  closed: 'OBX Demo - Closed Deal',
  approval: 'OBX Demo - Approval Track',
};

// ── Salesforce helpers ───────────────────────────────────────────────────────────────────

function apexString(value) {
  return value == null ? 'null' : `'${String(value).replace(/\\/g, '\\\\').replace(/'/g, "\\'")}'`;
}

function soql(query) {
  return sfJson(['data', 'query', '--query', query, ...orgArgs]).result.records;
}

function opportunity(name) {
  const [record] = soql(`SELECT Id, Discount__c, StageName, SystemModstamp FROM Opportunity WHERE Name = '${name}' LIMIT 1`);
  if (!record) throw new Error(`demo Opportunity "${name}" is missing; run scripts/salesforce/setup-org.mjs`);
  return record;
}

function resetDiscount(name, discount = 5) {
  runApex(`update new Opportunity(Id = [SELECT Id FROM Opportunity WHERE Name = ${apexString(name)} LIMIT 1].Id, Discount__c = ${discount});
System.debug(LoggingLevel.ERROR, 'OBX|ok');`, orgArgs);
}

function requestDiscount(name, discount, { justification = 'Strategic multi-year commitment', prompt } = {}) {
  const userPrompt = prompt ?? `Set the discount on ${name} to ${discount}%`;
  const [line] = runApex(
    `OpenBox_GovernedDiscountUpdate.Request r = new OpenBox_GovernedDiscountUpdate.Request();
r.opportunityId = [SELECT Id FROM Opportunity WHERE Name = ${apexString(name)} LIMIT 1].Id;
r.proposedDiscount = ${discount};
r.justification = ${apexString(justification)};
r.userPrompt = ${apexString(userPrompt)};
r.agentSessionId = 'e2e-' + String.valueOf(Datetime.now().getTime());
System.debug(LoggingLevel.ERROR, 'OBX|' + JSON.serialize(OpenBox_GovernedDiscountUpdate.updateDiscount(new List<OpenBox_GovernedDiscountUpdate.Request>{ r })[0]));`,
    orgArgs,
  );
  return JSON.parse(line);
}

function checkApproval(reference) {
  const [line] = runApex(
    `OpenBox_CheckDiscountApproval.Request r = new OpenBox_CheckDiscountApproval.Request();
r.requestReference = ${apexString(reference)};
System.debug(LoggingLevel.ERROR, 'OBX|' + JSON.serialize(OpenBox_CheckDiscountApproval.checkApproval(new List<OpenBox_CheckDiscountApproval.Request>{ r })[0]));`,
    orgArgs,
  );
  return JSON.parse(line);
}

function governedRequest(requestId) {
  const [record] = soql(
    `SELECT Id, Name, Status__c, Decision__c, Decision_Id__c, Justification__c, Workflow_Id__c, Activity_Id__c FROM OpenBox_Governed_Request__c WHERE Request_Id__c = '${requestId}'`,
  );
  return record;
}

function auditOutcomes(requestId) {
  return soql(`SELECT Outcome__c FROM OpenBox_Governance_Audit__c WHERE Request_Id__c = '${requestId}' ORDER BY Occurred_At__c, Name`).map(
    (row) => row.Outcome__c,
  );
}

async function drainOutbox(requestId, timeoutMs = 180000) {
  const deadline = Date.now() + timeoutMs;
  for (;;) {
    const rows = soql(
      `SELECT Status__c FROM OpenBox_Event_Outbox__c WHERE Governed_Request__r.Request_Id__c = '${requestId}'`,
    );
    const queued = rows.filter((row) => row.Status__c === 'Queued').length;
    if (queued === 0) return rows.map((row) => row.Status__c);
    if (Date.now() > deadline) throw new Error(`${queued} outbox events still queued after ${timeoutMs / 1000}s`);
    await sleep(5000);
  }
}

// ── OpenBox helpers ──────────────────────────────────────────────────────────────────────

/**
 * Where OpenBox stored a request. A request on its own is its own OpenBox session (run id = request
 * id); a request the agent made inside a governed conversation is a step of the conversation's
 * session, found by the conversation key and run id.
 */
function correlation(requestId) {
  const [record] = soql(
    `SELECT Run_Id__c, Agent_Session__r.Session_Key__c FROM OpenBox_Governed_Request__c WHERE Request_Id__c = '${requestId}'`,
  );
  const sessionKey = record?.Agent_Session__r?.Session_Key__c;
  return { runId: record?.Run_Id__c ?? requestId, sessionKey, key: sessionKey ?? requestId, conversation: Boolean(sessionKey) };
}

async function session(requestId, { attempts = 12 } = {}) {
  const { key } = correlation(requestId);
  for (let i = 0; i < attempts; i++) {
    const [match] = (await platform.findSessions(agentId, key)).filter((s) => s.workflow_id?.endsWith(key));
    if (match) {
      const rows = await platform.sessionLogs(agentId, match.id);
      if (rows.length) return { stored: match, rows };
    }
    await sleep(5000);
  }
  throw new Error(`OpenBox has no session for request ${requestId}`);
}

async function decide(requestId, action) {
  const { runId } = correlation(requestId);
  for (let i = 0; i < 12; i++) {
    const pending = (await platform.pendingApprovals(agentId)).find((row) => row.run_id === runId);
    if (pending) {
      await platform.decideApproval(agentId, pending.id, action);
      return pending;
    }
    await sleep(5000);
  }
  throw new Error(`no pending OpenBox approval for request ${requestId}`);
}

function verdictsOf(rows) {
  return rows.map((row) => `${row.event_type}:${row.activity_type}:${verdictName(row.verdict ?? row.action)}`);
}

// ── Assertions ───────────────────────────────────────────────────────────────────────────

class ScenarioFailure extends Error {}

function expect(condition, message) {
  if (!condition) throw new ScenarioFailure(message);
}

function expectEqual(actual, expected, label) {
  expect(actual === expected, `${label}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}

async function expectPairedSession(requestId, options = {}) {
  const { stored, rows } = await session(requestId);
  // A conversation's session stays open after each step; only idleness or a halt ends it.
  const conversationOpen = correlation(requestId).conversation && !options.expectHalt;
  const verification = verifySession(rows, conversationOpen ? { ...options, expectOpen: true } : options);
  expect(verification.ok, `pairing violations: ${verification.problems.join('; ')}\n${renderSession(rows)}`);
  return { stored, rows, verification };
}

// ── Scenarios ────────────────────────────────────────────────────────────────────────────

const scenarios = [
  {
    id: 'allow',
    title: `ALLOW: routine discount (<= ${THRESHOLDS.approvalAbove}%) is applied once`,
    async run() {
      resetDiscount(OPP.routine);
      const result = requestDiscount(OPP.routine, 10);
      expectEqual(result.status, 'Executed', 'status');
      expectEqual(result.decision, 'ALLOW', 'decision');
      expectEqual(opportunity(OPP.routine).Discount__c, 10, 'Opportunity discount');
      expectEqual(auditOutcomes(result.requestId).join(','), 'Allowed,Executed', 'audit trail');
      const outbox = await drainOutbox(result.requestId);
      expect(outbox.every((status) => status === 'Sent'), `outbox delivery ${outbox}`);
      const { rows, stored } = await expectPairedSession(result.requestId);
      expectEqual(stored.status, 'completed', 'OpenBox session status');
      expectEqual(
        rows.map((row) => `${row.event_type}:${row.activity_type}`).join(' > '),
        [
          'WorkflowStarted:Agentforce Sales Agent',
          'SignalReceived:user_prompt',
          'ActivityStarted:OpportunityLookup',
          'ActivityCompleted:OpportunityLookup',
          'ActivityStarted:OpportunityDiscountUpdate',
          'ActivityCompleted:OpportunityDiscountUpdate',
          'WorkflowCompleted:Agentforce Sales Agent',
        ].join(' > '),
        'stored event order',
      );
      return { requestNumber: result.requestNumber, decisionId: result.decisionId, verdicts: verdictsOf(rows) };
    },
  },
  {
    id: 'block',
    title: `BLOCK: discount above ${THRESHOLDS.blockAbove}% is refused without a write`,
    async run() {
      resetDiscount(OPP.routine);
      const result = requestDiscount(OPP.routine, 55);
      expectEqual(result.status, 'Blocked', 'status');
      expectEqual(result.decision, 'BLOCK', 'decision');
      expect(String(result.reason).includes(`${THRESHOLDS.blockAbove}%`), `reason ${result.reason}`);
      expectEqual(opportunity(OPP.routine).Discount__c, 5, 'Opportunity discount');
      expectEqual(auditOutcomes(result.requestId).join(','), 'Blocked', 'audit trail');
      const { rows } = await expectPairedSession(result.requestId);
      const decision = rows.find((row) => row.event_type === 'ActivityStarted' && row.activity_type === 'OpportunityDiscountUpdate');
      expectEqual(verdictName(decision.verdict), 'block', 'stored verdict');
      return { verdicts: verdictsOf(rows) };
    },
  },
  {
    id: 'halt',
    title: `HALT: discount of ${THRESHOLDS.haltAtOrAbove}%+ ends the agent session`,
    async run() {
      resetDiscount(OPP.routine);
      const result = requestDiscount(OPP.routine, 95);
      expectEqual(result.status, 'Halted', 'status');
      expectEqual(opportunity(OPP.routine).Discount__c, 5, 'Opportunity discount');
      const { stored, rows } = await expectPairedSession(result.requestId, { expectHalt: true });
      expectEqual(stored.status, 'halted', 'OpenBox session status');
      return { verdicts: verdictsOf(rows) };
    },
  },
  {
    id: 'closed',
    title: 'BLOCK: a closed Opportunity cannot be discounted (policy on record state)',
    async run() {
      const result = requestDiscount(OPP.closed, 8);
      expectEqual(result.status, 'Blocked', 'status');
      expect(String(result.reason).toLowerCase().includes('closed'), `reason ${result.reason}`);
      expectEqual(opportunity(OPP.closed).Discount__c, 5, 'Opportunity discount');
      await expectPairedSession(result.requestId);
      return {};
    },
  },
  {
    id: 'approve',
    title: `REQUIRE_APPROVAL: ${THRESHOLDS.approvalAbove}-${THRESHOLDS.blockAbove}% waits, then applies after a human approves`,
    async run() {
      resetDiscount(OPP.approval);
      const pending = requestDiscount(OPP.approval, 25);
      expectEqual(pending.status, 'Pending_Approval', 'status before approval');
      expectEqual(opportunity(OPP.approval).Discount__c, 5, 'no write before approval');
      await expectPairedSession(pending.requestId, { expectOpen: true });
      const stillPending = checkApproval(pending.requestNumber);
      expectEqual(stillPending.status, 'Pending_Approval', 'status while undecided');
      await decide(pending.requestId, 'approve');
      const executed = checkApproval(pending.requestNumber);
      expectEqual(executed.status, 'Executed', 'status after approval');
      expectEqual(opportunity(OPP.approval).Discount__c, 25, 'Opportunity discount');
      const replay = checkApproval(pending.requestNumber);
      expectEqual(replay.status, 'Executed', 'replayed check');
      expectEqual(
        auditOutcomes(pending.requestId).filter((outcome) => outcome === 'Executed').length,
        1,
        'committed mutations after replay',
      );
      await drainOutbox(pending.requestId);
      const { stored, rows } = await expectPairedSession(pending.requestId);
      expectEqual(stored.status, 'completed', 'OpenBox session status');
      return { requestNumber: pending.requestNumber, verdicts: verdictsOf(rows) };
    },
  },
  {
    id: 'reject',
    title: 'REQUIRE_APPROVAL then rejection: nothing is written',
    async run() {
      resetDiscount(OPP.approval);
      const pending = requestDiscount(OPP.approval, 30);
      expectEqual(pending.status, 'Pending_Approval', 'status before decision');
      await decide(pending.requestId, 'reject');
      const rejected = checkApproval(pending.requestNumber);
      expectEqual(rejected.status, 'Rejected', 'status after rejection');
      expectEqual(opportunity(OPP.approval).Discount__c, 5, 'Opportunity discount');
      await drainOutbox(pending.requestId);
      const { stored, rows } = await session(pending.requestId);
      return { sessionStatus: stored.status, verdicts: verdictsOf(rows), pairing: verifySession(rows, { expectHalt: true }).problems };
    },
  },
  {
    id: 'stale',
    title: 'Concurrent edit while awaiting approval: the approved request is refused as stale',
    async run() {
      resetDiscount(OPP.approval);
      const pending = requestDiscount(OPP.approval, 20);
      expectEqual(pending.status, 'Pending_Approval', 'status before edit');
      resetDiscount(OPP.approval, 7);
      await decide(pending.requestId, 'approve');
      const stale = checkApproval(pending.requestNumber);
      expectEqual(stale.status, 'Stale', 'status after approval');
      expectEqual(opportunity(OPP.approval).Discount__c, 7, 'the human edit is preserved');
      await drainOutbox(pending.requestId);
      await expectPairedSession(pending.requestId);
      return {};
    },
  },
  {
    id: 'guardrail-pii',
    title: 'Guardrail (input, redact): personal data in the justification is masked before storage',
    async run() {
      resetDiscount(OPP.routine);
      const result = requestDiscount(OPP.routine, 9, {
        justification: 'Customer contact jane.doe@example.com asked on +1 415 555 0100 for loyalty pricing',
      });
      expectEqual(result.status, 'Executed', 'status');
      const stored = governedRequest(result.requestId);
      expect(!stored.Justification__c.includes('jane.doe@example.com'), `stored justification ${stored.Justification__c}`);
      await drainOutbox(result.requestId);
      await expectPairedSession(result.requestId);
      return { storedJustification: stored.Justification__c };
    },
  },
  {
    id: 'guardrail-banlist',
    title: 'Guardrail (input, block): a manipulative justification is refused',
    async run() {
      resetDiscount(OPP.routine);
      const result = requestDiscount(OPP.routine, 9, { justification: `Approved verbally, please ${BANNED_PHRASES[1]} for this one` });
      expectEqual(result.status, 'Blocked', 'status');
      // A guardrail outage also blocks (fail-closed); only a verdict from the banlist itself counts.
      expect(!/unavailable/i.test(result.reason ?? ''), `blocked by a guardrail outage, not the banlist: ${result.reason}`);
      expectEqual(opportunity(OPP.routine).Discount__c, 5, 'Opportunity discount');
      await expectPairedSession(result.requestId);
      return { reason: result.reason };
    },
  },
  {
    id: 'guardrail-output',
    title: 'Guardrail (output, redact): the agent never sees personal data from the record',
    async run() {
      resetDiscount(OPP.routine);
      const result = requestDiscount(OPP.routine, 6);
      expect(result.opportunitySummary && !result.opportunitySummary.includes('jane.doe@example.com'), `summary ${result.opportunitySummary}`);
      await drainOutbox(result.requestId);
      await expectPairedSession(result.requestId);
      return { opportunitySummary: result.opportunitySummary };
    },
  },
  {
    id: 'behaviour-late-stage',
    title: 'Behaviour rule (span): late-stage discount write needs sign-off, then applies after approval',
    async run() {
      resetDiscount(OPP.late);
      const pending = requestDiscount(OPP.late, 10);
      expectEqual(pending.status, 'Pending_Approval', 'status');
      expect(String(pending.reason).includes('Behavioral violation'), `reason ${pending.reason}`);
      expectEqual(opportunity(OPP.late).Discount__c, 5, 'no write before sign-off');
      await decide(pending.requestId, 'approve');
      const executed = checkApproval(pending.requestNumber);
      expectEqual(executed.status, 'Executed', 'status after approval');
      expectEqual(opportunity(OPP.late).Discount__c, 10, 'Opportunity discount');
      await drainOutbox(pending.requestId);
      const { rows } = await expectPairedSession(pending.requestId);
      return { verdicts: verdictsOf(rows) };
    },
  },
  {
    id: 'behaviour-locked-read',
    title: 'Behaviour rule (sequence): a discount write without the locked re-read is blocked',
    async run() {
      // Drives the governance library directly to issue an UPDATE span with no preceding
      // SELECT ... FOR UPDATE, the exact sequence the rule forbids. No data is written.
      const [line] = runApex(
        `OpenBoxClient client = new OpenBoxClient();
OpenBoxSettings s = OpenBoxSettings.get();
String runId = OpenBoxIds.newRequestId();
OpenBoxEvents.Identity id = new OpenBoxEvents.Identity('salesforce-probe-' + runId, runId, s.workflowType, s.taskQueue, s.agentName, null);
OpenBoxGovernedRun run = OpenBoxGovernedRun.start(client, id, new Map<String, Object>{ 'probe' => 'behaviour-locked-read' }, 'Probe: write without a locked read');
OpenBoxGovernedRun.Activity a = run.newActivity('OpportunityDiscountUpdate');
Opportunity o = [SELECT Id, StageName, Discount__c FROM Opportunity WHERE Name = ${apexString(OPP.routine)} LIMIT 1];
OpenBoxEvaluationResult started = run.startActivity(a, new Map<String, Object>{ 'opportunity_id' => o.Id, 'proposed_discount' => 6, 'justification' => 'probe' });
OpenBoxSpan span = OpenBoxSpan.dmlUpdate(run.traceId, null, 'Opportunity', 'UPDATE Opportunity SET Discount__c = 6 WHERE Id = \\'' + o.Id + '\\'', new Map<String, Object>{ 'salesforce.opportunity.stage' => o.StageName });
OpenBoxEvaluationResult verdict = run.spanStarted(a, span);
if (verdict.isAllowed()) { span.failed('ProbeNotExecuted', 'probe never writes'); run.spanCompleted(a, span); run.failActivity(a, 'ProbeNotExecuted', 'probe never writes', null); }
run.finish(false, null, 'Probe', 'behaviour rule probe');
System.debug(LoggingLevel.ERROR, 'OBX|' + JSON.serialize(new Map<String, Object>{ 'runId' => runId, 'start' => started.verdict.name(), 'span' => verdict.verdict.name(), 'reason' => verdict.reason }));`,
        orgArgs,
      );
      const probe = JSON.parse(line);
      expectEqual(probe.start, 'ALLOW', 'activity decision');
      expectEqual(probe.span, 'BLOCK', 'write span verdict');
      expect(String(probe.reason).includes('locked read'), `reason ${probe.reason}`);
      expectEqual(opportunity(OPP.routine).Discount__c, 5, 'Opportunity discount');
      await expectPairedSession(probe.runId);
      return probe;
    },
  },
  {
    id: 'agentforce-conversation',
    title: 'Agentforce conversation: ALLOW, BLOCK and approval-required end to end through the real agent',
    async run() {
      // Judged on the data, never on the model's wording: each turn must leave the record, the
      // governed request and the OpenBox session in the state the verdict demands.
      resetDiscount(OPP.routine);
      resetDiscount(OPP.approval);
      const conversation = new AgentConversation(orgArgs).start();
      const turns = [];
      const latestRequest = () =>
        soql(
          `SELECT Name, Request_Id__c, Status__c, Decision__c FROM OpenBox_Governed_Request__c ORDER BY CreatedDate DESC LIMIT 1`,
        )[0];
      try {
        const say = (text) => {
          const reply = conversation.send(text);
          turns.push({ user: text, agent: reply });
          return reply;
        };
        say(`Set the discount on ${OPP.routine} to 12%. They committed to a three-year renewal.`);
        const allowed = latestRequest();
        expectEqual(allowed.Status__c, 'Executed', 'ALLOW turn status');
        expectEqual(opportunity(OPP.routine).Discount__c, 12, 'ALLOW turn discount');

        say(`Now make it 60% on ${OPP.routine}.`);
        const blocked = latestRequest();
        expectEqual(blocked.Status__c, 'Blocked', 'BLOCK turn status');
        expectEqual(opportunity(OPP.routine).Discount__c, 12, 'BLOCK turn leaves the discount');

        say(`Give ${OPP.approval} a 30% discount, they are matching a competitor quote.`);
        const pending = latestRequest();
        expectEqual(pending.Status__c, 'Pending_Approval', 'approval turn status');
        expectEqual(opportunity(OPP.approval).Discount__c, 5, 'approval turn writes nothing yet');
        await decide(pending.Request_Id__c, 'approve');

        say(`Has request ${pending.Name} been approved yet?`);
        expectEqual(governedRequest(pending.Request_Id__c).Status__c, 'Executed', 'approved request status');
        expectEqual(opportunity(OPP.approval).Discount__c, 30, 'approved discount applied');

        for (const request of [allowed, blocked, pending]) {
          await drainOutbox(request.Request_Id__c);
          await expectPairedSession(request.Request_Id__c);
        }
        return { transcript: turns, requests: [allowed.Name, blocked.Name, pending.Name] };
      } finally {
        conversation.end();
      }
    },
  },
  {
    id: 'goal-alignment',
    title: 'Goal alignment: the session goal is evaluated against the actions taken',
    async run() {
      resetDiscount(OPP.routine);
      const result = requestDiscount(OPP.routine, 7, {
        prompt: `Please apply a 7% loyalty discount to ${OPP.routine}`,
      });
      await drainOutbox(result.requestId);
      const { stored } = await session(result.requestId);
      const stats = await platform
        .request('GET', `/agent/${agentId}/sessions/${stored.id}/goal-alignment-stats`)
        .catch((error) => ({ error: error.message }));
      return { goal: stored.goal ?? null, stats };
    },
  },
];

// ── Runner ───────────────────────────────────────────────────────────────────────────────

const report = { startedAt: new Date().toISOString(), org: sfJson(['org', 'display', ...orgArgs]).result.username, agentId, results: [] };
let failures = 0;
for (const scenario of scenarios) {
  if (only && !only.has(scenario.id)) continue;
  const started = Date.now();
  process.stdout.write(`${scenario.id.padEnd(22)} ${scenario.title}\n`);
  try {
    const evidence = await scenario.run();
    report.results.push({ id: scenario.id, title: scenario.title, outcome: 'pass', ms: Date.now() - started, evidence });
    console.log(`${''.padEnd(22)} PASS (${((Date.now() - started) / 1000).toFixed(1)}s)`);
  } catch (error) {
    failures++;
    report.results.push({ id: scenario.id, title: scenario.title, outcome: 'fail', ms: Date.now() - started, error: error.message });
    console.log(`${''.padEnd(22)} FAIL ${error.message}`);
  }
}
report.finishedAt = new Date().toISOString();
mkdirSync(resolve(PROJECT_ROOT, 'out'), { recursive: true });
writeFileSync(resolve(PROJECT_ROOT, 'out', 'e2e-report.json'), JSON.stringify(report, null, 2));
console.log(`\n${report.results.length - failures}/${report.results.length} scenarios passed; report: out/e2e-report.json`);
process.exitCode = failures ? 1 : 0;
