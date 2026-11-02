import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const app = await readFile(new URL('../site/src/app.mjs', import.meta.url), 'utf8');
const html = await readFile(new URL('../site/index.html', import.meta.url), 'utf8');
const styles = await readFile(new URL('../site/src/styles.css', import.meta.url), 'utf8');
const migration = await readFile(new URL('../supabase/migrations/202611020009_fix_workspace_refresh_trigger.sql', import.meta.url), 'utf8');

test('optional admin role controls use a collection selector before forEach', () => {
  assert.match(app, /\$\$\('\[data-admin-role-save\]'\)\.forEach/);
  assert.equal(app.split('\n').some((line) => line.trimStart().startsWith("$('[data-admin-role-save]')")), false);
});

test('workspace refresh trigger safely checks presence fields only through row JSON', () => {
  assert.match(migration, /if tg_table_name = 'member_presence' then\s+if tg_op = 'UPDATE' then/);
  assert.match(migration, /to_jsonb\(new\)->>'presence_state'/);
  assert.match(migration, /to_jsonb\(old\)->>'presence_state'/);
  assert.doesNotMatch(migration, /new\.presence_state|old\.presence_state/);
});

test('startup loader uses the WHO\'S next mark and animated progress treatment', () => {
  assert.match(html, /class="loader-emblem"/);
  assert.match(html, /class="loader-mark">W/);
  assert.match(html, /class="loader-progress"/);
  assert.match(styles, /@keyframes loader-mark-pulse/);
  assert.match(styles, /@keyframes loader-progress/);
});

test('access-code submission shows a spinner and restores the button after failure', () => {
  assert.match(app, /button\.setAttribute\('aria-busy', 'true'\)/);
  assert.match(app, /class="button-spinner"/);
  assert.match(app, /button\.removeAttribute\('aria-busy'\)/);
});
