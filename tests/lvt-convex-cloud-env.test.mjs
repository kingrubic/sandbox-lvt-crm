import assert from 'node:assert/strict';
import { mkdtemp, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import test from 'node:test';

const cloudEnv = fileURLToPath(new URL('../scripts/lvt-convex-cloud-env.sh', import.meta.url));
const selfHostedEnv = fileURLToPath(new URL('../scripts/lvt-convex-self-hosted-env.sh', import.meta.url));
const zshAvailable = spawnSync('zsh', ['-c', 'exit 0'], { encoding: 'utf8' }).status === 0;
const skip = zshAvailable ? false : 'zsh is required to execute the Convex wrappers';

const DEV_KEY = 'dev:decisive-puma-318|fake-dev-key';
const PROD_KEY = 'prod:confident-guanaco-953|fake-prod-key';

async function keysFile(row) {
  const dir = await mkdtemp(path.join(tmpdir(), 'lvt-convex-keys-'));
  const file = path.join(dir, 'keys.csv');
  await writeFile(file, `name,key prod,key dev,acc email\nOther,prod:other-1|x,,\n${row}\n`);
  return file;
}

function run(script, args, env = {}) {
  return spawnSync(script, args, {
    encoding: 'utf8',
    env: {
      PATH: process.env.PATH,
      HOME: process.env.HOME,
      CONVEX_SELF_HOSTED_URL: 'http://127.0.0.1:3210',
      CONVEX_SELF_HOSTED_ADMIN_KEY: 'stale-admin-key',
      CONVEX_DEPLOYMENT: 'prod:confident-guanaco-953',
      ...env,
    },
  });
}

const printEnv = ['/bin/sh', '-c', 'printf "%s\\n%s\\n%s\\n%s\\n" "$CONVEX_DEPLOY_KEY" "$CONVEX_DEPLOYMENT" "$CONVEX_SELF_HOSTED_URL" "$CONVEX_SELF_HOSTED_ADMIN_KEY"'];

test('dev target passes only the dev key and blanks self-hosted settings', { skip }, async () => {
  const file = await keysFile(`LVT-CRM,${PROD_KEY},${DEV_KEY},`);
  const result = run(cloudEnv, ['dev', ...printEnv], { LVT_CONVEX_KEYS_FILE: file });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(result.stdout.split('\n').slice(0, 4), [DEV_KEY, '', '', '']);
});

test('a key that belongs to another deployment is refused', { skip }, async () => {
  const file = await keysFile(`LVT-CRM,${PROD_KEY},${PROD_KEY},`);
  const result = run(cloudEnv, ['dev', 'true'], { LVT_CONVEX_KEYS_FILE: file });
  assert.equal(result.status, 78);
  assert.match(result.stderr, /not for dev:decisive-puma-318/);
  assert.doesNotMatch(result.stderr, /fake-prod-key/);
});

test('prod target requires explicit confirmation', { skip }, async () => {
  const file = await keysFile(`LVT-CRM,${PROD_KEY},${DEV_KEY},`);
  const refused = run(cloudEnv, ['prod', ...printEnv], { LVT_CONVEX_KEYS_FILE: file });
  assert.equal(refused.status, 77);
  assert.match(refused.stderr, /LVT_CONVEX_CONFIRM_PROD=confident-guanaco-953/);
  assert.equal(refused.stdout, '');
});

test('unknown targets and missing commands print usage', { skip }, () => {
  assert.equal(run(cloudEnv, ['staging', 'true']).status, 64);
  assert.equal(run(cloudEnv, ['dev']).status, 64);
});

test('retired self-hosted wrapper never runs the command', { skip }, () => {
  const result = run(selfHostedEnv, ['/bin/sh', '-c', 'echo ran']);
  assert.equal(result.status, 78);
  assert.equal(result.stdout, '');
  assert.match(result.stderr, /retired/);
});
