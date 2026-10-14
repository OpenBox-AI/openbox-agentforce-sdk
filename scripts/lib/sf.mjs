// Thin wrapper over the Salesforce CLI for the operator scripts. The CLI's own Node entry point
// is executed directly, so arguments are passed as an argument vector and never through a shell.

import { execSync, spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

let entryPoint;

function sfEntryPoint() {
  if (!entryPoint) {
    const globalRoot = execSync('npm root -g', { encoding: 'utf8' }).trim();
    entryPoint = join(globalRoot, '@salesforce', 'cli', 'bin', 'run.js');
    if (!existsSync(entryPoint)) {
      throw new Error(`Salesforce CLI not found at ${entryPoint}; install it with "npm install -g @salesforce/cli"`);
    }
  }
  return entryPoint;
}

export function targetOrgArgs(argv) {
  const index = argv.indexOf('--target-org');
  const alias = index >= 0 ? argv[index + 1] : process.env.SF_TARGET_ORG;
  return alias ? ['--target-org', alias] : [];
}

/**
 * Runs an sf command, from `cwd` when given (deploys need the directory of an sfdx project). With
 * `raw`, returns stdout; otherwise parses `--json` output and throws on a non-zero status (unless
 * `allowFailure`), surfacing the CLI's own error message.
 */
export function sfJson(args, { raw = false, allowFailure = false, cwd } = {}) {
  const fullArgs = raw ? args : [...args, '--json'];
  const run = spawnSync(process.execPath, [sfEntryPoint(), ...fullArgs], {
    cwd,
    encoding: 'utf8',
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, SF_DISABLE_TELEMETRY: 'true', SF_AUTOUPDATE_DISABLE: 'true' },
  });
  if (raw) {
    if (run.status !== 0) throw new Error(`sf ${args[0]} ${args[1]} failed: ${(run.stderr || run.stdout).trim()}`);
    return run.stdout;
  }
  let parsed;
  try {
    parsed = JSON.parse(run.stdout);
  } catch {
    throw new Error(`sf ${args.join(' ')} returned non-JSON output: ${(run.stderr || run.stdout).slice(0, 500)}`);
  }
  if (parsed.status !== 0 && !allowFailure) throw new Error(`sf ${args[0]} ${args[1]} failed: ${parsed.message ?? JSON.stringify(parsed)}`);
  return parsed;
}

const HTML_ENTITIES = { '&#124;': '|', '&quot;': '"', '&#39;': "'", '&lt;': '<', '&gt;': '>', '&amp;': '&' };

function decodeLogText(text) {
  return text.replace(/&#124;|&quot;|&#39;|&lt;|&gt;|&amp;/g, (entity) => HTML_ENTITIES[entity]);
}

/**
 * Executes anonymous Apex and returns, in order, the payloads it wrote with
 * System.debug(LoggingLevel.ERROR, '<marker>' + payload). Debug logs HTML-escape their text;
 * payloads are returned decoded.
 */
export function runApex(source, orgArgs, marker = 'OBX|') {
  const directory = mkdtempSync(join(tmpdir(), 'openbox-apex-'));
  const file = join(directory, 'script.apex');
  try {
    writeFileSync(file, source);
    const { result } = sfJson(['apex', 'run', '--file', file, ...orgArgs]);
    if (!result.compiled) throw new Error(`Apex did not compile: ${result.compileProblem}`);
    if (!result.success) throw new Error(`Apex failed: ${result.exceptionMessage}\n${result.exceptionStackTrace}`);
    return (result.logs ?? '')
      .split(/\r?\n/)
      .filter((line) => line.includes('|USER_DEBUG|'))
      .map((line) => decodeLogText(line.slice(line.indexOf('|USER_DEBUG|') + '|USER_DEBUG|'.length)))
      .map((line) => line.replace(/^\[\d+\]\|ERROR\|/, ''))
      .filter((line) => line.startsWith(marker))
      .map((line) => line.slice(marker.length));
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}
