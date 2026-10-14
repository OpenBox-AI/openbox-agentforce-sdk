// Lists and decides pending OpenBox approvals for the Agentforce agent, as a human approver
// would in the OpenBox dashboard.
//
//   node scripts/openbox/approvals.mjs list
//   node scripts/openbox/approvals.mjs approve <request-id | governance-event-id>
//   node scripts/openbox/approvals.mjs reject  <request-id | governance-event-id>

import { loadEnv, requireEnv } from '../lib/env.mjs';
import { OpenBoxPlatform } from '../lib/openbox-platform.mjs';

loadEnv();
const [command, reference] = process.argv.slice(2);
const platform = new OpenBoxPlatform({
  apiKey: requireEnv('OPENBOX_ORG_API_KEY'),
  baseUrl: process.env.OPENBOX_PLATFORM_API_URL,
});
const agentId = requireEnv('OPENBOX_AGENT_ID');

async function findPending(match) {
  const pending = await platform.pendingApprovals(agentId);
  return pending.filter(
    (row) => !match || row.id === match || row.run_id === match || String(row.workflow_id ?? '').includes(match),
  );
}

if (command === 'list') {
  for (const row of await findPending()) {
    console.log(
      `${row.id}  ${row.activity_type}  run=${row.run_id}  expires=${row.approval_expiration_time ?? row.approval_expired_at ?? ''}  ${row.reason ?? ''}`,
    );
  }
} else if (command === 'approve' || command === 'reject') {
  if (!reference) {
    console.error(`usage: approvals.mjs ${command} <request-id | governance-event-id>`);
    process.exit(2);
  }
  const [match] = await findPending(reference);
  if (!match) {
    console.error(`no pending approval matches ${reference}`);
    process.exit(1);
  }
  await platform.decideApproval(agentId, match.id, command);
  console.log(`${command}d ${match.id} (${match.activity_type}, run ${match.run_id})`);
} else {
  console.error('usage: approvals.mjs list | approve <ref> | reject <ref>');
  process.exit(2);
}
