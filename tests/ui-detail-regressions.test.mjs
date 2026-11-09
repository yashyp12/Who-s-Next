import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const html = await readFile(new URL('../site/index.html', import.meta.url), 'utf8');
const css = await readFile(new URL('../site/src/styles.css', import.meta.url), 'utf8');

test('application shell does not render an escaped newline as visible text', () => {
  assert.doesNotMatch(html, /<\/div>\\n\s*<dialog/);
  assert.match(html, /<div id="tour-root"><\/div>\s*<dialog id="action-dialog"/);
});

test('the existing guided tour presentation remains unchanged', () => {
  assert.match(css, /\.intro-tour-backdrop\s*\{[^}]*background:\s*rgba\(4,\s*8,\s*13,\s*\.78\)/s);
  assert.match(css, /\.intro-tour-card\s*\{[^}]*left:\s*50%/s);
  assert.doesNotMatch(css, /A compact, non-blocking guide/);
});

test('dense operational lists keep their own scroll areas', () => {
  for (const selector of ['.schedule-list', '.request-list', '.queue-list', '.activity-list', '.analytics-agent-list']) {
    assert.ok(css.includes(selector), `missing ${selector}`);
  }
  assert.match(css, /\.schedule-list,\.request-list,\.queue-list,\.activity-list,\.analytics-agent-list\s*\{[^}]*overflow-y:\s*auto/s);
  assert.match(css, /\.table-wrap\s*\{[^}]*overflow:\s*auto/s);
});

test('header controls wrap at narrower widths without being hidden', () => {
  assert.match(css, /\.topbar\s*\{[^}]*flex-wrap:\s*wrap/s);
  assert.match(css, /\.top-actions\s*\{[^}]*flex-wrap:\s*wrap/s);
  assert.match(css, /#tour-replay\s*\{[^}]*flex:\s*0\s+0\s+auto/s);
});

test('interactive controls have a visible keyboard focus treatment', () => {
  assert.match(css, /:focus-visible/);
});
