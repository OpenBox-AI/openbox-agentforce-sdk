// Publishes and activates the reference Agentforce agent.
//
//   node scripts/salesforce/publish-agent.mjs [--target-org <alias>] [--api-name OpenBox_Sales_Agent]
//
// `sf agent publish authoring-bundle` only looks in a project's default package directory, which here
// is force-app (the packaged SDK), while the agent's bundle lives in reference-agent. The bundle also
// names the user the agent runs as, which differs per org. So the bundle is published from a
// temporary copy of reference-agent, made the default package directory, with `default_agent_user` set
// to SF_AGENT_USERNAME (saved to .env by create-agent-user.mjs). Files in the repository are not
// modified.
import { cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { PROJECT_ROOT, loadEnv, requireEnv } from '../lib/env.mjs';
import { sfJson, targetOrgArgs } from '../lib/sf.mjs';

loadEnv();
const orgArgs = targetOrgArgs(process.argv);
const apiNameIndex = process.argv.indexOf('--api-name');
const apiName = apiNameIndex > -1 ? process.argv[apiNameIndex + 1] : 'OpenBox_Sales_Agent';
const agentUser = requireEnv('SF_AGENT_USERNAME');

const project = JSON.parse(readFileSync(resolve(PROJECT_ROOT, 'sfdx-project.json'), 'utf8'));
const workspace = mkdtempSync(join(tmpdir(), 'openbox-agent-'));
try {
  cpSync(resolve(PROJECT_ROOT, 'reference-agent'), join(workspace, 'reference-agent'), { recursive: true });
  writeFileSync(
    join(workspace, 'sfdx-project.json'),
    JSON.stringify(
      {
        packageDirectories: [{ path: 'reference-agent', default: true }],
        name: project.name,
        namespace: project.namespace,
        sfdcLoginUrl: project.sfdcLoginUrl,
        sourceApiVersion: project.sourceApiVersion,
      },
      null,
      2,
    ),
  );

  const bundle = join(workspace, 'reference-agent', 'main', 'default', 'aiAuthoringBundles', apiName, `${apiName}.agent`);
  const source = readFileSync(bundle, 'utf8');
  const userLine = /^(\s*default_agent_user:\s*)"[^"]*"/m;
  if (!userLine.test(source)) throw new Error(`${apiName}.agent has no default_agent_user to set`);
  writeFileSync(bundle, source.replace(userLine, `$1${JSON.stringify(agentUser)}`));

  sfJson(['agent', 'publish', 'authoring-bundle', '--api-name', apiName, '--skip-retrieve', ...orgArgs], { cwd: workspace });
  console.log(`published ${apiName} (runs as ${agentUser})`);
  sfJson(['agent', 'activate', '--api-name', apiName, ...orgArgs], { cwd: workspace });
  console.log(`activated ${apiName}`);
} finally {
  rmSync(workspace, { recursive: true, force: true });
}
