// Prints a governed run as OpenBox stored it and verifies its event and span pairing.
//
//   node scripts/openbox/inspect-session.mjs <request-id | workflow-id> [--open] [--halt] [--json]
//
// Exits 1 when the stored run violates the pairing contract.

import { loadEnv, requireEnv } from '../lib/env.mjs';
import { OpenBoxPlatform } from '../lib/openbox-platform.mjs';
import { renderSession, verifySession } from '../lib/session-verifier.mjs';

loadEnv();
const [reference] = process.argv.slice(2).filter((arg) => !arg.startsWith('--'));
if (!reference) {
  console.error('usage: inspect-session.mjs <request-id | workflow-id> [--open] [--halt] [--json]');
  process.exit(2);
}

const platform = new OpenBoxPlatform({
  apiKey: requireEnv('OPENBOX_ORG_API_KEY'),
  baseUrl: process.env.OPENBOX_PLATFORM_API_URL,
});
const agentId = requireEnv('OPENBOX_AGENT_ID');

const sessions = await platform.findSessions(agentId, reference);
const session =
  sessions.find((candidate) => candidate.workflow_id?.includes(reference) || candidate.run_id === reference) ??
  sessions[0];
if (!session) {
  console.error(`no OpenBox session matches ${reference}`);
  process.exit(1);
}
const rows = await platform.sessionLogs(agentId, session.id);

if (process.argv.includes('--json')) {
  console.log(JSON.stringify({ session, rows }, null, 2));
  process.exit(0);
}

console.log(`session ${session.id}  status=${session.status}  workflow=${session.workflow_id}`);
console.log(renderSession(rows));
const result = verifySession(rows, {
  expectOpen: process.argv.includes('--open'),
  expectHalt: process.argv.includes('--halt'),
});
console.log(
  `\n${result.summary.events.length} events, ${result.summary.activities} activities, ${result.summary.spans} spans (${result.summary.spanRows} span rows)`,
);
if (result.ok) {
  console.log('PAIRING OK');
} else {
  console.log(`PAIRING VIOLATIONS:\n  - ${result.problems.join('\n  - ')}`);
  process.exitCode = 1;
}
