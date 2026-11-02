import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const source = await readFile(new URL('../site/src/notifications.mjs', import.meta.url), 'utf8');
const css = await readFile(new URL('../site/src/styles.css', import.meta.url), 'utf8');

test('notification sound defaults on and remembers the member preference', () => {
  assert.match(source, /let soundEnabled = true/);
  assert.match(source, /saved === null \? true : saved === 'true'/);
  assert.match(source, /localStorage\.setItem\(SOUND_KEY, String\(soundEnabled\)\)/);
});

test('new notifications use realtime events and a polling fallback', () => {
  assert.match(source, /postgres_changes/);
  assert.match(source, /window\.setInterval\([\s\S]*?3000\)/);
  assert.match(source, /notifyNewItem\(\{/);
  assert.match(source, /seenNotificationIds\.has/);
});

test('notification control is icon-only and assignment alerts are visible', () => {
  assert.match(source, /class="notification-trigger"/);
  assert.match(source, /<svg viewBox="0 0 24 24"/);
  assert.match(source, /notification-toast-copy/);
  assert.match(css, /\.notification-trigger\{[^}]*width:38px/s);
  assert.match(css, /\.notification-toast\{[^}]*position:fixed/s);
});
