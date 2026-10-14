// Deploys the package source (force-app) and the reference agent (reference-agent) with the package's
// Apex tests.
//
//   node scripts/salesforce/deploy.mjs [--target-org <alias>] [--dry-run] [--destructive <manifest>]
//
// --destructive deletes the components listed in a destructiveChanges manifest in the same deploy,
// after the new source is applied (so nothing still deployed can reference them): needed when
// components are removed from force-app, because a source deploy never deletes from the org.
//
// Salesforce refuses to redeploy classes referenced by a scheduled job, so the OpenBox hourly
// safety-net schedule is removed before the deploy and reinstalled afterwards, whether or not the
// deploy succeeds. Nothing else in the org is touched.
//
// Source carries the live OpenBox endpoints. When .env names another environment
// (OPENBOX_CORE_URL), the deploy re-applies it with configure-endpoints.mjs, so a redeploy never
// silently repoints the org.

import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { PROJECT_ROOT, loadEnv } from '../lib/env.mjs';
import { runApex, sfJson, targetOrgArgs } from '../lib/sf.mjs';

loadEnv();
const orgArgs = targetOrgArgs(process.argv);
const dryRun = process.argv.includes('--dry-run');
const destructiveIndex = process.argv.indexOf('--destructive');
const destructive = destructiveIndex > -1 ? resolve(process.argv[destructiveIndex + 1]) : null;

const SOURCE_DIRS = ['force-app', 'reference-agent'].flatMap((dir) => ['--source-dir', resolve(PROJECT_ROOT, dir)]);

function deployTarget(workspace) {
  if (!destructive) return SOURCE_DIRS;
  sfJson(['project', 'generate', 'manifest', ...SOURCE_DIRS, '--output-dir', workspace], {
    cwd: PROJECT_ROOT,
  });
  return ['--manifest', join(workspace, 'package.xml'), '--post-destructive-changes', destructive];
}

function removeSchedule() {
  const [removed] = runApex(
    `Integer removed = 0;
for (CronTrigger job : [SELECT Id FROM CronTrigger WHERE CronJobDetail.Name LIKE 'OpenBox approval poller%']) {
    System.abortJob(job.Id);
    removed++;
}
System.debug(LoggingLevel.ERROR, 'OBX|' + removed);`,
    orgArgs,
  );
  return Number(removed);
}

function installSchedule() {
  const [cronId] = runApex(`System.debug(LoggingLevel.ERROR, 'OBX|' + OpenBoxApprovalPollerSchedule.install());`, orgArgs);
  return cronId;
}

const paused = dryRun ? 0 : removeSchedule();
if (paused) console.log(`paused ${paused} OpenBox schedule(s) for the deploy`);
let failed = false;
const workspace = mkdtempSync(join(tmpdir(), 'openbox-deploy-'));
try {
  const args = ['project', 'deploy', 'start', ...deployTarget(workspace), '--test-level', 'RunLocalTests', '--wait', '30', ...orgArgs];
  if (dryRun) args.push('--dry-run');
  const run = sfJson(args, { allowFailure: true, cwd: PROJECT_ROOT });
  const result = run.result ?? {};
  if (run.status !== 0 || result.success === false) {
    failed = true;
    const details = result.details ?? {};
    const components = [details.componentFailures ?? []].flat();
    const tests = [details.runTestResult?.failures ?? []].flat();
    const lines = [
      ...components.map((f) => `  component ${f.componentType} ${f.fullName}${f.lineNumber ? `:${f.lineNumber}` : ''} - ${f.problem}`),
      ...tests.map((t) => `  test ${t.name}.${t.methodName} - ${t.message}`),
    ];
    const summary = lines.length ? `:\n${lines.join('\n')}` : `: ${run.message}`;
    throw new Error(`deploy failed${summary}`);
  }
  const tests = result.details?.runTestResult ?? {};
  console.log(
    `${dryRun ? 'validated' : 'deployed'} ${result.numberComponentsDeployed}/${result.numberComponentsTotal} components; ` +
      `${tests.numTestsRun ?? 0} tests run, ${tests.numFailures ?? 0} failed (deploy ${result.id})`,
  );
} finally {
  rmSync(workspace, { recursive: true, force: true });
  if (!dryRun && !failed && process.env.OPENBOX_CORE_URL) {
    const configure = spawnSync(
      process.execPath,
      [resolve(PROJECT_ROOT, 'scripts', 'salesforce', 'configure-endpoints.mjs'), ...orgArgs],
      { stdio: 'inherit' },
    );
    if (configure.status !== 0) failed = true;
  }
  if (paused || (!dryRun && !failed)) {
    console.log(`approval poller schedule: ${installSchedule()}`);
  }
}
