// The old Iroh soak is retired. These are entrypoint refusal tests, not soak passes.
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readdirSync, readFileSync, rmSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const cases = [
  ['scripts/run-iroh-release-gate.sh', []],
  ['scripts/run-iroh-release-gate.sh', ['--production', '--mode', 'automatic']],
  ['scripts/mobile-dev-launch.sh', ['--iroh-release-gate', 'automatic']],
  ['scripts/mobile-dev-launch.sh', ['--iroh-release-gate']],
  ['scripts/mobile-dev-launch.sh', ['--restore-pairing']],
];
for (const [script, args] of cases) {
  test(`retired entrypoint refuses without tools, credentials or state: ${script} ${args.join(' ')}`, (t) => {
    const dir = mkdtempSync(path.join(os.tmpdir(), 'cmux-retired-iroh-'));
    t.after(() => rmSync(dir, { recursive: true, force: true }));
    const home = path.join(dir, 'home');
    const bin = path.join(dir, 'bin');
    mkdirSync(home); mkdirSync(bin);
    const trace = path.join(dir, 'tool-trace');
    for (const tool of ['dirname', 'sed', 'cat', 'stat', 'curl', 'security', 'xcrun', 'defaults', 'bun', 'python3', 'mkdir']) {
      writeFileSync(path.join(bin, tool), '#!/bin/bash\nprintf "%s\\n" "$0" >> "$SPY_TRACE"\nexit 97\n', { mode: 0o755 });
    }
    const credentials = path.join(home, 'credentials.env');
    writeFileSync(credentials, 'printf "credential-source\\n" >> "$SPY_TRACE"\n', { mode: 0o600 });
    const content = readFileSync(credentials, 'utf8');
    const commandArgs = script === 'scripts/run-iroh-release-gate.sh' && args.length === 0
      ? [] : [...args, '--credentials-file', credentials];
    const result = spawnSync('/bin/bash', [path.join(root, script), ...commandArgs], {
      cwd: home, encoding: 'utf8', timeout: 5000,
      env: { HOME: home, CFFIXED_USER_HOME: home, PATH: bin, SPY_TRACE: trace, TMPDIR: home },
    });
    assert.equal(result.status, 64, result.stderr);
    assert.match(result.stderr, /unsupported/);
    assert.equal(result.stdout, '');
    assert.deepEqual(readdirSync(home), ['credentials.env']);
    assert.equal(readFileSync(credentials, 'utf8'), content);
    assert.deepEqual(readdirSync(dir).sort(), ['bin', 'home']);
  });
}
