// Ensures the Salesforce certificate that holds the OpenBox workload signing key, and publishes its
// public key for OpenBox registration.
//
//   node scripts/salesforce/workload-certificate.mjs [--target-org <alias>]
//
// The certificate is self-signed and generated inside Salesforce (RSA 2048, private key not
// exportable): the private key never exists anywhere else. Its public key is converted to the JWK
// that OpenBox registers for the agent's Keycloak service account, and written to .env as
// OPENBOX_WORKLOAD_PUBLIC_JWK for scripts/openbox/provision.mjs. An existing certificate is reused,
// never regenerated, because regenerating it would invalidate the key OpenBox trusts.

import { X509Certificate, createHash } from 'node:crypto';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, join } from 'node:path';
import { ENV_PATH, loadEnv, saveEnv } from '../lib/env.mjs';
import { sfJson, targetOrgArgs } from '../lib/sf.mjs';

export const CERTIFICATE_NAME = 'OpenBox_Workload';

loadEnv();
const orgArgs = targetOrgArgs(process.argv);
// The CLI deploys and retrieves only inside an sfdx project, so the work happens in a throwaway one.
const workspace = mkdtempSync(join(tmpdir(), 'openbox-certificate-'));
const certs = join(workspace, 'force-app', 'certs');
mkdirSync(certs, { recursive: true });
writeFileSync(
  join(workspace, 'sfdx-project.json'),
  JSON.stringify({ packageDirectories: [{ path: 'force-app', default: true }], sourceApiVersion: '66.0' }),
);

function exists() {
  const { result } = sfJson(['org', 'list', 'metadata', '--metadata-type', 'Certificate', ...orgArgs]);
  return (result ?? []).some((item) => item.fullName === CERTIFICATE_NAME);
}

function create() {
  // An empty certificate body asks Salesforce to generate the key pair and a self-signed certificate.
  writeFileSync(join(certs, `${CERTIFICATE_NAME}.crt`), '');
  writeFileSync(join(certs, `${CERTIFICATE_NAME}.crt-meta.xml`), `<?xml version="1.0" encoding="UTF-8"?>
<Certificate xmlns="http://soap.sforce.com/2006/04/metadata">
    <caSigned>false</caSigned>
    <encryptedWithPlatformEncryption>false</encryptedWithPlatformEncryption>
    <keySize>2048</keySize>
    <masterLabel>OpenBox Workload</masterLabel>
    <privateKeyExportable>false</privateKeyExportable>
</Certificate>
`);
  sfJson(['project', 'deploy', 'start', '--source-dir', 'force-app', ...orgArgs], { cwd: workspace });
}

function publicCertificate() {
  sfJson(['project', 'retrieve', 'start', '--metadata', `Certificate:${CERTIFICATE_NAME}`, '--output-dir', 'retrieved', ...orgArgs], {
    cwd: workspace,
  });
  return new X509Certificate(readFileSync(join(workspace, 'retrieved', 'certs', `${CERTIFICATE_NAME}.crt`)));
}

try {
  const created = !exists();
  if (created) create();
  const certificate = publicCertificate();
  const { n, e } = certificate.publicKey.export({ format: 'jwk' });
  const fingerprint = createHash('sha256').update(certificate.raw).digest('hex').slice(0, 16);
  const { result: org } = sfJson(['org', 'display', ...orgArgs]);
  const jwk = { kty: 'RSA', kid: `salesforce-${org.id}-${fingerprint}`, alg: 'RS256', use: 'sig', n, e };
  saveEnv({ OPENBOX_WORKLOAD_PUBLIC_JWK: JSON.stringify(jwk) });
  console.log(`certificate ${created ? 'created' : 'exists '}  ${CERTIFICATE_NAME} (expires ${certificate.validTo})`);
  console.log(`public key  ${jwk.kid} saved to ${basename(ENV_PATH)}`);
} finally {
  rmSync(workspace, { recursive: true, force: true });
}
