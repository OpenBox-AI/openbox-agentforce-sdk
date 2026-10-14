// Prepares a Salesforce org for the OpenBox governed discount action.
//
//   node scripts/salesforce/setup-org.mjs [--target-org <alias>] [--skip-deploy]
//
// 1. Deploys force-app and the reference agent, and runs the package's Apex tests.
// 2. Assigns OpenBox_Governance_Admin to the operating admin.
// 3. Stores the OpenBox runtime key in the External Credential.
// 4. Seeds the demo Opportunities used by the live test suite.
// 5. Installs the hourly approval-poller safety net.

import { spawnSync } from 'node:child_process';
import { resolve } from 'node:path';
import { PROJECT_ROOT, loadEnv } from '../lib/env.mjs';
import { runApex, sfJson, targetOrgArgs } from '../lib/sf.mjs';

loadEnv();
const orgArgs = targetOrgArgs(process.argv);

export const DEMO_OPPORTUNITIES = [
  { name: 'OBX Demo - Routine Renewal', stage: 'Prospecting', amount: 48000, discount: 5 },
  { name: 'OBX Demo - Late Stage Expansion', stage: 'Negotiation/Review', amount: 250000, discount: 5 },
  { name: 'OBX Demo - Closed Deal', stage: 'Closed Won', amount: 90000, discount: 5 },
  { name: 'OBX Demo - Approval Track', stage: 'Qualification', amount: 130000, discount: 5 },
];

function step(title, action) {
  process.stdout.write(`${title} ... `);
  const outcome = action();
  console.log(outcome ?? 'done');
}

if (!process.argv.includes('--skip-deploy')) {
  step('deploy force-app and reference-agent, run local tests', () => {
    const deploy = sfJson([
      'project',
      'deploy',
      'start',
      '--source-dir',
      resolve(PROJECT_ROOT, 'force-app'),
      '--source-dir',
      resolve(PROJECT_ROOT, 'reference-agent'),
      '--test-level',
      'RunLocalTests',
      '--wait',
      '30',
      ...orgArgs,
    ]);
    const tests = deploy.result.details?.runTestResult;
    return `deployed ${deploy.result.numberComponentsDeployed} components; tests ${tests?.numTestsRun ?? '?'} run, ${tests?.numFailures ?? '?'} failed`;
  });
}

step('assign OpenBox_Governance_Admin to the operating user', () => {
  try {
    sfJson(['org', 'assign', 'permset', '--name', 'OpenBox_Governance_Admin', ...orgArgs]);
    return 'assigned';
  } catch (error) {
    if (/duplicate/i.test(error.message)) return 'already assigned';
    throw error;
  }
});

step('store the OpenBox runtime key in OpenBox_Core_Auth', () => {
  const run = spawnSync(process.execPath, [resolve(PROJECT_ROOT, 'scripts/salesforce/set-credential.mjs'), ...orgArgs], { encoding: 'utf8' });
  if (run.status !== 0) throw new Error(run.stderr || run.stdout);
  return run.stdout.trim();
});

step('seed demo opportunities', () => {
  const rows = DEMO_OPPORTUNITIES.map(
    (o) =>
      `new Opportunity(Name = '${o.name}', StageName = '${o.stage}', Amount = ${o.amount}, Discount__c = ${o.discount}, CloseDate = Date.today().addDays(45), Description = 'Champion: jane.doe@example.com, +1 415 555 0100. Renewal risk: moderate.')`,
  );
  const names = DEMO_OPPORTUNITIES.map((o) => `'${o.name}'`).join(', ');
  const output = runApex(
    `delete [SELECT Id FROM Opportunity WHERE Name IN (${names})];
insert new List<Opportunity>{ ${rows.join(', ')} };
System.debug(LoggingLevel.ERROR, 'OBX|' + [SELECT COUNT() FROM Opportunity WHERE Name IN (${names})]);`,
    orgArgs,
  );
  return `${output[0]} opportunities ready`;
});

step('install hourly approval-poller safety net', () => {
  const output = runApex(`System.debug(LoggingLevel.ERROR, 'OBX|' + OpenBoxApprovalPollerSchedule.install());`, orgArgs);
  return `CronTrigger ${output[0]}`;
});
