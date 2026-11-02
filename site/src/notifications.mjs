let activeClient = null;
let activeMemberId = null;
let channel = null;
let notifications = [];
let isOpen = false;
let soundEnabled = false;
let root = null;

const escapeHtml = (value = '') => String(value).replace(/[&<>"']/g, (char) => ({
  '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
}[char]));

function relativeTime(value) {
  const timestamp = new Date(value).getTime();
  if (!Number.isFinite(timestamp)) return 'Just now';
  const minutes = Math.max(0, Math.floor((Date.now() - timestamp) / 60000));
  if (minutes < 1) return 'Just now';
  if (minutes < 60) return \`\${minutes}m ago\`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return \`\${hours}h ago\`;
  return new Intl.DateTimeFormat(undefined, { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' }).format(new Date(timestamp));
}

function playNotificationSound() {
  if (!soundEnabled) return;
  try {
    const AudioContextClass = window.AudioContext || window.webkitAudioContext;
    if (!AudioContextClass) return;
    const context = new AudioContextClass();
    const oscillator = context.createOscillator();
    const gain = context.createGain();
    oscillator.type = 'sine';
    oscillator.frequency.value = 880;
    gain.gain.setValueAtTime(0.0001, context.currentTime);
    gain.gain.exponentialRampToValueAtTime(0.12, context.currentTime + 0.015);
    gain.gain.exponentialRampToValueAtTime(0.0001, context.currentTime + 0.22);
    oscillator.connect(gain);
    gain.connect(context.destination);
    oscillator.start();
    oscillator.stop(context.currentTime + 0.23);
    oscillator.onended = () => context.close();
  } catch { /* Audio is optional; notification delivery must not depend on it. */ }
}

function showLiveToast(item) {
  const previous = document.querySelector('.notification-toast');
  previous?.remove();
  const toast = document.createElement('div');
  toast.className = 'toast notification-toast';
  toast.innerHTML = \`<strong>\${escapeHtml(item.title)}</strong><div>\${escapeHtml(item.body)}</div>\`;
  document.body.append(toast);
  window.setTimeout(() => toast.remove(), 5000);
}

function renderList() {
  if (!root) return;
  const unread = notifications.filter((item) => !item.readAt).length;
  root.innerHTML = \`
    <button type="button" class="button button-secondary button-small notification-trigger" id="notification-trigger" aria-expanded="\${isOpen}" aria-label="Notifications, \${unread} unread">
      <span aria-hidden="true">♢</span> Notifications \${unread ? \`<span class="notification-count">\${unread > 99 ? '99+' : unread}</span>\` : ''}
    </button>
    \${isOpen ? \`<section class="notification-popover" aria-label="Notifications">
      <div class="notification-popover-head">
        <div><strong>Notifications</strong><small>\${unread} unread · latest 30</small></div>
        <button type="button" class="text-link" id="notification-sound">\${soundEnabled ? 'Sound on' : 'Enable sound'}</button>
      </div>
      <div class="notification-items">
        \${notifications.length ? notifications.map((item) => \`
          <button type="button" class="notification-item \${item.readAt ? '' : 'unread'}" data-notification-id="\${escapeHtml(item.id)}">
            <span class="notification-dot"></span>
            <span class="notification-copy"><strong>\${escapeHtml(item.title)}</strong><span>\${escapeHtml(item.body)}</span><small>\${escapeHtml(item.actorName || 'WHO’S next')} · \${relativeTime(item.createdAt)}</small></span>
          </button>\`).join('') : '<div class="empty-state">You’re all caught up. New assignments and request updates will appear here.</div>'}
      </div>
    </section>\` : ''}\`;
  root.querySelector('#notification-trigger')?.addEventListener('click', () => {
    isOpen = !isOpen;
    renderList();
  });
  root.querySelector('#notification-sound')?.addEventListener('click', () => {
    soundEnabled = !soundEnabled;
    renderList();
    if (soundEnabled) playNotificationSound();
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

async function loadNotifications() {
  if (!activeClient || !activeMemberId) return;
  const { data, error } = await activeClient.rpc('get_my_notifications', { p_limit: 30 });
  if (error) throw error;
  notifications = Array.isArray(data) ? data : [];
  renderList();
}

function subscribe(client, memberId) {
  if (channel) {
    client.removeChannel(channel);
    channel = null;
  }
  channel = client.channel(\`whos-next-notifications-\${memberId}\`)
    .on('postgres_changes', {
      event: 'INSERT',
      schema: 'public',
      table: 'notifications',
      filter: \`recipient_member_id=eq.\${memberId}\`,
    }, (payload) => {
      const row = payload.new || {};
      if (notifications.some((item) => item.id === row.id)) return;
      loadNotifications().then(() => {
        const item = notifications.find((entry) => entry.id === row.id);
        if (item) {
          showLiveToast(item);
          playNotificationSound();
        }
      }).catch((error) => console.error('Unable to refresh notifications:', error));
    })
    .subscribe((status) => {
      if (status === 'CHANNEL_ERROR' || status === 'TIMED_OUT') {
        console.warn('Notification live updates are unavailable; manual refresh remains available.');
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
    subscribe(supabase, memberId);
    loadNotifications().catch((error) => console.error('Unable to load notifications:', error));
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
