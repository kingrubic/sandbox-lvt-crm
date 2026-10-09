import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

// Ratchet for DESIGN.md: per CSS file, hardcoded colors and sub-scale text may
// go down but never up. Lower the numbers in design-baseline.json when you
// clean a file; never raise them to make a PR pass.
const root = fileURLToPath(new URL('../', import.meta.url));
const baseline = JSON.parse(await readFile(new URL('./design-baseline.json', import.meta.url), 'utf8'));

async function cssFiles(dir) {
  const entries = await readdir(path.join(root, dir), { withFileTypes: true });
  const nested = await Promise.all(entries.map((entry) => {
    const relative = path.posix.join(dir, entry.name);
    if (entry.isDirectory()) return cssFiles(relative);
    return entry.name.endsWith('.css') ? [relative] : [];
  }));
  return nested.flat();
}

export function designDebt(css) {
  const withoutTokenDefinitions = css.replace(/--[a-z0-9-]+\s*:[^;]+;/gi, '');
  const hex = (withoutTokenDefinitions.match(/#[0-9a-f]{3,8}\b/gi) || []).length;
  let smallText = 0;
  for (const [, body] of css.matchAll(/[^{}]+\{([^{}]*)\}/g)) {
    const minimum = /text-transform:\s*uppercase/.test(body) ? 11 : 12;
    for (const [, size, unit] of body.matchAll(/font-size:\s*([0-9.]+)(px|rem)\b/g)) {
      if (Number(size) * (unit === 'rem' ? 16 : 1) < minimum) smallText += 1;
    }
  }
  return { hex, smallText };
}

test('CSS design debt never grows (hardcoded colors, text below the DESIGN.md scale)', async () => {
  const files = await cssFiles('src');
  const regressions = [];
  for (const file of files.sort()) {
    const current = designDebt(await readFile(path.join(root, file), 'utf8'));
    const allowed = baseline[file] || { hex: 0, smallText: 0 };
    for (const metric of ['hex', 'smallText']) {
      if (current[metric] > allowed[metric]) {
        regressions.push(`${file}: ${metric} ${current[metric]} > baseline ${allowed[metric]}`);
      }
    }
  }
  assert.deepEqual(regressions, [], 'Use --lvt-* tokens and the DESIGN.md type scale instead of adding new debt');
});
