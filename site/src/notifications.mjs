let activeClient = null;
let activeMemberId = null;
let channel = null;
let notifications = [];
let isOpen = false;
let soundEnabled = true;
let audioContext = null;
let root = null;
let initialLoadComplete = false;
let pollTimer = null;
const seenNotificationIds = new Set();
const SOUND_KEY = 'whos-next-notification-sound';

try {
  const saved = localStorage.getItem(SOUND_KEY);
  soundEnabled = saved === null ? true : saved === 'true';
} catch { soundEnabled = true; }

const escapeHtml = (value = '') => String(value).replace(/[&<>"']/g, (char) => ({
  '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
}[char]));

function relativeTime(value) {
  const timestamp = new Date(value).getTime();
  if (!Number.isFinite(timestamp)) return 'Just now';
  const minutes = Math.max(0, Math.floor((Date.now() - timestamp) / 60000));
  if (minutes < 1) return 'Just now';
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  return new Intl.DateTimeFormat(undefined, { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' }).format(new Date(timestamp));
}

function unlockAudio() {
  if (audioContext) {
    if (audioContext.state === 'suspended') audioContext.resume().catch(() => {});
    return;
  }
  try {
    const AudioContextClass = window.AudioContext || window.webkitAudioContext;
    if (!AudioContextClass) return;
    audioContext = new AudioContextClass();
    if (audioContext.state === 'suspended') audioContext.resume().catch(() => {});
  } catch { /* Audio is optional; notification delivery must not depend on it. */ }
}

document.addEventListener('pointerdown', unlockAudio, { once: true, capture: true });
document.addEventListener('keydown', unlockAudio, { once: true, capture: true });

function playNotificationSound() {
  if (!soundEnabled || !audioContext) return;
  try {
    if (audioContext.state === 'suspended') audioContext.resume().catch(() => {});
    const oscillator = audioContext.createOscillator();
    const gain = audioContext.createGain();
    oscillator.type = 'sine';
    oscillator.frequency.setValueAtTime(880, audioContext.currentTime);
    gain.gain.setValueAtTime(0.0001, audioContext.currentTime);
    gain.gain.exponentialRampToValueAtTime(0.14, audioContext.currentTime + 0.02);
    gain.gain.exponentialRampToValueAtTime(0.0001, audioContext.currentTime + 0.28);
    oscillator.connect(gain);
    gain.connect(audioContext.destination);
    oscillator.start();
    oscillator.stop(audioContext.currentTime + 0.29);
  } catch { /* Browser audio permissions must never interrupt workspace actions. */ }
}

function showLiveToast(item) {
  document.querySelector('.notification-toast')?.remove();
  const toast = document.createElement('div');
  toast.className = 'notification-toast';
  toast.setAttribute('role', 'status');
  toast.setAttribute('aria-live', 'polite');
  const mark = document.createElement('span');
  mark.className = 'notification-toast-mark';
  mark.textContent = '↗';
  const copy = document.createElement('div');
  copy.className = 'notification-toast-copy';
  const title = document.createElement('strong');
  title.textContent = item.title || 'New workspace update';
  const body = document.createElement('span');
  body.textContent = item.body || 'Open notifications to see the details.';
  copy.append(title, body);
  const close = document.createElement('button');
  close.type = 'button';
  close.className = 'notification-toast-close';
  close.setAttribute('aria-label', 'Dismiss notification');
  close.textContent = '×';
  close.addEventListener('click', () => toast.remove());
  toast.append(mark, copy, close);
  document.body.append(toast);
  window.setTimeout(() => toast.remove(), 6500);
}

function notifyNewItem(item) {
  if (!item?.id || seenNotificationIds.has(item.id)) return;
  seenNotificationIds.add(item.id);
  notifications = [item, ...notifications.filter((entry) => entry.id !== item.id)].slice(0, 30);
  renderList();
  showLiveToast(item);
  playNotificationSound();
}

function renderList() {
  if (!root) return;
  const unread = notifications.filter((item) => !item.readAt).length;
  root.innerHTML = `
    <button type="button" class="notification-trigger" id="notification-trigger" aria-expanded="${isOpen}" aria-label="Notifications, ${unread} unread" title="Notifications">
      <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M18 8a6 6 0 0 0-12 0c0 7-3 7-3 9h18c0-2-3-2-3-9M10 21h4"/></svg>
      ${unread ? `<span class="notification-count">${unread > 99 ? '99+' : unread}</span>` : ''}
    </button>
    ${isOpen ? `<section class="notification-popover" aria-label="Notifications">
      <div class="notification-popover-head">
        <div><strong>Notifications</strong><small>${unread} unread</small></div>
        <button type="button" class="text-link" id="notification-sound" aria-pressed="${soundEnabled}">Sound ${soundEnabled ? 'on' : 'off'}</button>
      </div>
      <div class="notification-items">
        ${notifications.length ? notifications.map((item) => `
          <button type="button" class="notification-item ${item.readAt ? '' : 'unread'}" data-notification-id="${escapeHtml(item.id)}">
            <span class="notification-dot"></span>
            <span class="notification-copy"><strong>${escapeHtml(item.title)}</strong><span>${escapeHtml(item.body)}</span><small>${escapeHtml(item.actorName || 'WHO’S next')} · ${relativeTime(item.createdAt)}</small></span>
          </button>`).join('') : '<div class="empty-state">You’re all caught up.</div>'}
      </div>
    </section>` : ''}`;
  root.querySelector('#notification-trigger')?.addEventListener('click', () => {
    isOpen = !isOpen;
    renderList();
  });
  root.querySelector('#notification-sound')?.addEventListener('click', () => {
    soundEnabled = !soundEnabled;
    try { localStorage.setItem(SOUND_KEY, String(soundEnabled)); } catch { /* Preference remains active for this tab. */ }
    if (soundEnabled) { unlockAudio(); playNotificationSound(); }
    renderList();
  });
  root.querySelectorAll('[data-notification-id]').forEach((button) => {
    button.addEventListener('click', async () => {
      const notificationId = button.dataset.notificationId;
      const item = notifications.find((entry) => entry.id === notificationId);
      if (!item || item.readAt) return;
      try {
        const { error } = await activeClient.rpc('mark_my_notification_read', { p_notification_id: notificationId });
        if (error) throw error;
        item.readAt = new Date().toISOString();
        renderList();
      } catch (error) {
        console.error('Unable to mark notification as read:', error);
      }
    });
  });
}

async function loadNotifications({ notify = false } = {}) {
  if (!activeClient || !activeMemberId) return;
  const { data, error } = await activeClient.rpc('get_my_notifications', { p_limit: 30 });
  if (error) throw error;
  const next = Array.isArray(data) ? data : [];
  if (!initialLoadComplete) {
    notifications = next;
    next.forEach((item) => { if (item.id) seenNotificationIds.add(item.id); });
    initialLoadComplete = true;
  } else {
    if (notify) {
      const previousIds = new Set(notifications.map((item) => item.id));
      for (const item of [...next].reverse()) {
        if (!previousIds.has(item.id) && !seenNotificationIds.has(item.id)) notifyNewItem(item);
      }
    }
    notifications = next.map((item) => {
      const current = notifications.find((entry) => entry.id === item.id);
      return current ? { ...item, readAt: item.readAt || current.readAt } : item;
    });
    next.forEach((item) => { if (item.id) seenNotificationIds.add(item.id); });
  }
  renderList();
}

function subscribe(client, memberId) {
  if (channel) {
    client.removeChannel(channel);
    channel = null;
  }
  channel = client.channel(`whos-next-notifications-${memberId}`)
    .on('postgres_changes', {
      event: 'INSERT',
      schema: 'public',
      table: 'notifications',
      filter: `recipient_member_id=eq.${memberId}`,
    }, (payload) => {
      const row = payload.new || {};
      notifyNewItem({
        id: row.id,
        type: row.notification_type,
        title: row.title,
        body: row.body,
        entityType: row.entity_type,
        entityId: row.entity_id,
        createdAt: row.created_at || new Date().toISOString(),
        readAt: row.read_at || null,
        actorName: null,
      });
    })
    .subscribe((status) => {
      if (status === 'CHANNEL_ERROR' || status === 'TIMED_OUT') {
        console.warn('Notification realtime is unavailable; polling fallback remains active.');
      }
    });
}

export function initializeNotificationCenter({ supabase, memberId }) {
  if (!supabase || !memberId) return;
  if (activeClient !== supabase || activeMemberId !== memberId) {
    activeClient = supabase;
    activeMemberId = memberId;
    notifications = [];
    isOpen = false;
    initialLoadComplete = false;
    seenNotificationIds.clear();
    subscribe(supabase, memberId);
    loadNotifications().catch((error) => console.error('Unable to load notifications:', error));
    if (pollTimer) window.clearInterval(pollTimer);
    pollTimer = window.setInterval(() => {
      loadNotifications({ notify: true }).catch((error) => console.error('Notification sync failed:', error));
    }, 8000);
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'visible') loadNotifications({ notify: true }).catch((error) => console.error('Notification refresh failed:', error));
    });
    window.addEventListener('focus', () => loadNotifications({ notify: true }).catch((error) => console.error('Notification refresh failed:', error)));
  }
  const topActions = document.querySelector('.top-actions');
  if (!topActions) return;
  root = topActions.querySelector('.notification-center');
  if (!root) {
    root = document.createElement('div');
    root.className = 'notification-center';
    topActions.prepend(root);
  }
  renderList();
}
