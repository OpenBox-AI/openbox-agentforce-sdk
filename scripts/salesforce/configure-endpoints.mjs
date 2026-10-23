// Points a Salesforce org at one OpenBox environment (live by default in source; staging or a
// preview environment through .env).
//
//   node scripts/salesforce/configure-endpoints.mjs [--target-org <alias>]
//
// Reads OPENBOX_CORE_URL and asks that Core, with the agent's API key, which identity issuer the
// agent's workload identity belongs to. It then deploys, to the org only:
//   - the OpenBox_Core Named Credential URL (Core),
//   - the OpenBox_Identity Remote Site Setting (the issuer's origin),
//   - OpenBox_Settings__mdt.Default.Identity_Issuer__c (the one issuer Apex will trust).
// Files in force-app are not modified.

import { cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { PROJECT_ROOT, loadEnv, requireEnv } from '../lib/env.mjs';
import { sfJson, targetOrgArgs } from '../lib/sf.mjs';

loadEnv();
const orgArgs = targetOrgArgs(process.argv);
const coreUrl = new URL(requireEnv('OPENBOX_CORE_URL')).origin;

async function workloadIssuer() {
  const response = await fetch(`${coreUrl}/api/v3/auth/bootstrap`, {
    headers: { Authorization: `Bearer ${requireEnv('OPENBOX_AGENT_API_KEY')}`, Accept: 'application/json' },
    signal: AbortSignal.timeout(20000),
  });
  if (!response.ok) throw new Error(`workload bootstrap returned HTTP ${response.status}: ${await response.text()}`);
  const { issuer, token_endpoint: tokenEndpoint } = await response.json();
  if (!issuer?.startsWith('https://') || tokenEndpoint !== `${issuer.replace(/\/$/, '')}/protocol/openid-connect/token`) {
    throw new Error('workload bootstrap returned an unusable issuer');
  }
  return issuer.replace(/\/$/, '');
}

function replaceTag(xml, tag, value, after = '') {
  const pattern = new RegExp(`(${after}[\\s\\S]*?<${tag}(?:\\s[^>]*)?>)[^<]*(</${tag}>)`);
  if (!pattern.test(xml)) throw new Error(`<${tag}> not found`);
  return xml.replace(pattern, `$1${value}$2`);
}

const issuer = await workloadIssuer();
const source = resolve(PROJECT_ROOT, 'force-app', 'main', 'default');
const workspace = mkdtempSync(join(tmpdir(), 'openbox-endpoints-'));
try {
  const target = join(workspace, 'force-app', 'main', 'default');
  writeFileSync(
    join(workspace, 'sfdx-project.json'),
    JSON.stringify({ packageDirectories: [{ path: 'force-app', default: true }], sourceApiVersion: '66.0' }),
  );

  const namedCredential = 'namedCredentials/OpenBox_Core.namedCredential-meta.xml';
  mkdirSync(join(target, 'namedCredentials'), { recursive: true });
  writeFileSync(
    join(target, namedCredential),
    replaceTag(readFileSync(join(source, namedCredential), 'utf8'), 'parameterValue', coreUrl, '<parameterName>Url</parameterName>'),
  );

  const remoteSite = 'remoteSiteSettings/OpenBox_Identity.remoteSite-meta.xml';
  mkdirSync(join(target, 'remoteSiteSettings'), { recursive: true });
  writeFileSync(join(target, remoteSite), replaceTag(readFileSync(join(source, remoteSite), 'utf8'), 'url', new URL(issuer).origin));

  const settings = 'customMetadata/OpenBox_Settings.Default.md-meta.xml';
  mkdirSync(join(target, 'customMetadata'), { recursive: true });
  writeFileSync(
    join(target, settings),
    replaceTag(readFileSync(join(source, settings), 'utf8'), 'value', issuer, '<field>Identity_Issuer__c</field>'),
  );
  cpSync(join(source, 'objects', 'OpenBox_Settings__mdt'), join(target, 'objects', 'OpenBox_Settings__mdt'), { recursive: true });

  sfJson(['project', 'deploy', 'start', '--source-dir', 'force-app', '--test-level', 'NoTestRun', '--ignore-conflicts', ...orgArgs], { cwd: workspace });
  console.log(`core      ${coreUrl}`);
  console.log(`identity  ${issuer}`);
} finally {
  rmSync(workspace, { recursive: true, force: true });
}
