// Stores the OpenBox agent's runtime key in Salesforce.
//
//   node scripts/salesforce/set-credential.mjs [--target-org <alias>]
//
// The key (OPENBOX_AGENT_API_KEY) goes into the External Credential OpenBox_Core_Auth through the
// Connect REST named-credentials endpoint: it lands in the platform's encrypted credential store and
// is injected by the Named Credential at callout time. It travels only in a temporary request-body
// file that is deleted immediately, and never appears in Apex, metadata, debug logs, command lines
// or this script's output. The agent's other credential, the workload signing key, is generated
// inside Salesforce by scripts/salesforce/workload-certificate.mjs and never leaves it.

import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { loadEnv, requireEnv } from '../lib/env.mjs';
import { sfJson, targetOrgArgs } from '../lib/sf.mjs';

loadEnv();
const orgArgs = targetOrgArgs(process.argv);
const { result: org } = sfJson(['org', 'display', ...orgArgs]);
const base = `/services/data/v${org.apiVersion}`;
const directory = mkdtempSync(join(tmpdir(), 'openbox-credential-'));

function restWithBody(method, path, body) {
  const file = join(directory, 'body.json');
  writeFileSync(file, JSON.stringify(body), { mode: 0o600 });
  try {
    return sfJson(['api', 'request', 'rest', path, '--method', method, '--body', `@${file}`, ...orgArgs], { raw: true });
  } finally {
    rmSync(file, { force: true });
  }
}

function storeRuntimeKey() {
  const body = {
    externalCredential: 'OpenBox_Core_Auth',
    principalName: 'AgentRuntimeKey',
    principalType: 'NamedPrincipal',
    credentials: { ApiKey: { value: requireEnv('OPENBOX_AGENT_API_KEY'), encrypted: true } },
  };
  try {
    restWithBody('POST', `${base}/named-credentials/credential`, body);
    return 'created';
  } catch {
    restWithBody('PUT', `${base}/named-credentials/credential`, body);
    return 'updated';
  }
}

try {
  console.log(`runtime key: ${storeRuntimeKey()} in OpenBox_Core_Auth/AgentRuntimeKey`);
} finally {
  rmSync(directory, { recursive: true, force: true });
}
