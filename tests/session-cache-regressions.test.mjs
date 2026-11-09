import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const app = await readFile(new URL('../site/src/app.mjs', import.meta.url), 'utf8');
const html = await readFile(new URL('../site/index.html', import.meta.url), 'utf8');
const netlify = await readFile(new URL('../netlify.toml', import.meta.url), 'utf8');

test('Supabase workspace login is tab-scoped and survives reloads only within that tab session', () => {
  assert.match(app, /persistSession:\s*true/);
  assert.match(app, /storage:\s*window\.sessionStorage/);
  assert.doesNotMatch(app, /storage:\s*window\.localStorage/);
});

test('legacy persistent Supabase token is removed so it cannot silently restore an old login', () => {
  assert.match(app, /localStorage\.removeItem\(\`sb-\$\{projectRef\}-auth-token\`\)/);
  assert.match(app, /new URL\(CONFIG\.supabaseUrl\)/);
});

test('explicit sign-out still performs the server-side offline handover before clearing auth', () => {
  const signOut = app.slice(app.indexOf('async function signOut()'), app.indexOf('function latestAttendanceForCurrentMember()'));
  assert.ok(signOut.indexOf("supabase.rpc('set_member_offline')") < signOut.indexOf('supabase.auth.signOut()'));
  assert.match(signOut, /handover\.current_assignee_id === currentMemberId/);
  assert.match(signOut, /window\.location\.reload\(\)/);
});

test('HTML application shell and runtime config are never served from a stale browser cache', () => {
  assert.match(netlify, /for = "\/"/);
  assert.match(netlify, /for = "\/index\.html"/);
  assert.match(netlify, /for = "\/config\.js"/);
  assert.match(netlify, /Cache-Control = "no-store, no-cache, must-revalidate"/);
});

test('all frontend modules revalidate before reuse and static asset URLs are versioned', () => {
  assert.match(netlify, /for = "\/src\/\*"/);
  assert.match(netlify, /Cache-Control = "no-cache, must-revalidate"/);
  assert.match(html, /styles\.css\?v=20261109-responsive-analytics-v2/);
  assert.match(html, /app\.mjs\?v=20261109-responsive-analytics-v2/);
});
