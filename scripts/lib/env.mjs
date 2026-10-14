// Environment loading and .env persistence for the operator scripts.
// Secrets are written to .env and never echoed; callers print key names only.

import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

export const PROJECT_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
// OPENBOX_ENV_FILE selects another file (e.g. .env.pkg-test) so a second org keeps its own agent
// and key without touching the main .env.
export const ENV_PATH = resolve(PROJECT_ROOT, process.env.OPENBOX_ENV_FILE || '.env');

export function loadEnv() {
  if (existsSync(ENV_PATH)) {
    process.loadEnvFile(ENV_PATH);
  }
}

export function requireEnv(name) {
  const value = process.env[name];
  if (!value) {
    throw new Error(`${name} is not set; add it to ${ENV_PATH}`);
  }
  return value;
}

/** Sets keys in .env, replacing existing lines for the same keys and keeping everything else. */
export function saveEnv(values) {
  const lines = existsSync(ENV_PATH) ? readFileSync(ENV_PATH, 'utf8').split(/\r?\n/).filter(Boolean) : [];
  const kept = lines.filter((line) => !(line.split('=', 1)[0].trim() in values));
  for (const [key, value] of Object.entries(values)) {
    if (value !== undefined && value !== null && value !== '') {
      kept.push(`${key}=${value}`);
      process.env[key] = String(value);
    }
  }
  writeFileSync(ENV_PATH, `${kept.join('\n')}\n`, { mode: 0o600 });
}
