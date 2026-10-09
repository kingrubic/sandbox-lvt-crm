import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const read = (relative) => readFile(new URL(`../${relative}`, import.meta.url), 'utf8');

function cssRules(css) {
  return [...css.matchAll(/([^{}]+)\{([^{}]*)\}/g)].map(([, selector, body]) => ({ selector: selector.trim(), body }));
}

test('shared contrast tokens keep their accessible values', async () => {
  const styles = await read('src/styles.css');
  assert.match(styles, /--lvt-muted: #5a6b7c;/);
  assert.match(styles, /--lvt-teal-text: #0e7363;/);
  assert.match(styles, /--lvt-coral-strong: #c0472f;/);
  assert.doesNotMatch(styles, /(?<![-\w])color: var\(--lvt-teal\)/, 'teal text must use --lvt-teal-text');
  assert.match(styles, /\.nav-badge \{[^}]*background: var\(--lvt-coral-strong\)/);
});

test('settings pages (management theme) keep readable text and 14px inputs', async () => {
  const css = await read('src/management/managementTheme.css');
  for (const { selector, body } of cssRules(css)) {
    for (const [, size] of body.matchAll(/font-size:\s*([0-9.]+)px/g)) {
      assert.ok(Number(size) >= 12, `${selector} uses ${size}px`);
      if (/\b(input|select|textarea)\b/.test(selector) && !/radio|label/.test(selector)) {
        assert.ok(Number(size) >= 14, `${selector} input text is ${size}px`);
      }
    }
  }
});

test('Báo cáo uses the app font; Times New Roman stays only on the official Lịch công tác table', async () => {
  const reports = await read('src/reports/dutyCalendar.css');
  assert.doesNotMatch(reports, /Georgia|Times New Roman/);
  const schedule = await read('src/duties/sharedDutySchedule.css');
  assert.match(schedule, /font-family: "Times New Roman"/);
  const design = await read('DESIGN.md');
  assert.match(design, /Ngoại lệ duy nhất:\*\* bảng lịch chính thức của \*\*Lịch công tác\*\*/);
});
