/* ══════════════════════════════════════════════════════════
   CONFIG
══════════════════════════════════════════════════════════ */
const API = 'http://localhost:8001';

// Frontend fetch timeout for /chat/send. Kept slightly above the
// backend's Ollama timeout (30s, see orchestrator.py OLLAMA_TIMEOUT)
// so the backend gets a chance to fail gracefully and return an error
// event before the browser gives up on its own. If you change one,
// change the other and keep this a few seconds ahead.
const CHAT_SEND_TIMEOUT_MS = 35000;

/* ══════════════════════════════════════════════════════════
   AUTH GUARD
══════════════════════════════════════════════════════════ */
const TOKEN    = localStorage.getItem('hepozy_token');
const USERNAME = localStorage.getItem('hepozy_username') || 'User';

if (!TOKEN) {
  window.location.href = 'login.html';
}

/* ══════════════════════════════════════════════════════════
   ELEMENTS
══════════════════════════════════════════════════════════ */
const sidebar     = document.getElementById('sidebar');
const mobOverlay  = document.getElementById('mobOverlay');
const mobMenuBtn  = document.getElementById('mobMenuBtn');
const messagesEl  = document.getElementById('messages');
const centerState = document.getElementById('centerState');
const inputArea   = document.getElementById('inputArea');
const historyList = document.getElementById('historyList');
const topbarTitle = document.getElementById('topbarTitle');
const profileMenu = document.getElementById('profileMenu');
const settingsBg  = document.getElementById('settingsBackdrop');

/* ══════════════════════════════════════════════════════════
   INIT UI
══════════════════════════════════════════════════════════ */
document.getElementById('profileName').textContent      = USERNAME;
document.getElementById('settingsUsername').textContent = USERNAME;
document.getElementById('avatarCircle').textContent     = USERNAME.charAt(0).toUpperCase();
document.getElementById('welcomeTitle').textContent     = `Hi, ${USERNAME}`;

/* ══════════════════════════════════════════════════════════
   STATE
══════════════════════════════════════════════════════════ */
let conversations       = [];
let activeId             = null;
let conversationStarted  = false;
let sidebarLocked        = false;
let streaming            = false;

const isMobile = () => window.innerWidth <= 640;

/* ══════════════════════════════════════════════════════════
   SIDEBAR
══════════════════════════════════════════════════════════ */
function toggleSidebar() {
  if (isMobile()) { openMobile(); return; }
  sidebarLocked = !sidebarLocked;
  sidebar.classList.toggle('open', sidebarLocked);
}

function openMobile() {
  sidebar.classList.add('mobile-open');
  mobOverlay.classList.add('show');
}

function closeMobile() {
  sidebar.classList.remove('mobile-open');
  mobOverlay.classList.remove('show');
}

function applyResponsive() {
  if (isMobile()) {
    mobMenuBtn.style.display = 'flex';
    if (!mobOverlay.classList.contains('show')) {
      sidebar.classList.remove('mobile-open');
    }
  } else {
    mobMenuBtn.style.display = 'none';
    mobOverlay.classList.remove('show');
    sidebar.classList.toggle('open', sidebarLocked);
  }
}

applyResponsive();
window.addEventListener('resize', applyResponsive);

function focusSearch() {
  if (!isMobile() && !sidebarLocked) {
    sidebarLocked = true;
    sidebar.classList.add('open');
  }
  if (isMobile()) openMobile();
  setTimeout(() => document.getElementById('searchInput').focus(), 220);
}

/* ══════════════════════════════════════════════════════════
   PROFILE MENU
══════════════════════════════════════════════════════════ */
function toggleProfileMenu() { profileMenu.classList.toggle('show'); }

function goToSettings() {
  profileMenu.classList.remove('show');
  openSettings();
}

document.addEventListener('click', (e) => {
  if (!e.target.closest('.sidebar-bottom')) {
    profileMenu.classList.remove('show');
  }
});

/* ══════════════════════════════════════════════════════════
   SETTINGS MODAL
══════════════════════════════════════════════════════════ */
function openSettings()  { settingsBg.classList.add('show');    }
function closeSettings() { settingsBg.classList.remove('show'); }

/* ══════════════════════════════════════════════════════════
   LOGOUT
══════════════════════════════════════════════════════════ */
function logout() {
  localStorage.removeItem('hepozy_token');
  localStorage.removeItem('hepozy_username');
  window.location.href = 'login.html';
}

/* ══════════════════════════════════════════════════════════
   TEXTAREA AUTO RESIZE
══════════════════════════════════════════════════════════ */
function autoResize(el) {
  el.style.height = 'auto';
  el.style.height = Math.min(el.scrollHeight, 120) + 'px';
  el.style.overflowY = el.scrollHeight > 120 ? 'auto' : 'hidden';
}

function handleKey(e, src) {
  if (e.key === 'Enter' && !e.shiftKey) {
    e.preventDefault();
    sendMessage(src);
  }
}

/* ══════════════════════════════════════════════════════════
   IMAGE STAGING — select = preview only, nothing sent yet.
   Actual send happens only when sendMessage() runs (Send click
   or Enter key), which flushes stagedFiles into the chat.

   FIX: renderStagedPreview() looks up #bottomInputBox / #centerInputBox
   by id. #bottomInputBox previously pointed at a dead, empty div at
   the end of <body> (never the visible input box), so previews were
   rendering into an invisible element. The id now lives on the real
   .input-box inside #inputArea (see home.html) — no JS change needed
   here, this was purely an HTML id placement bug.
══════════════════════════════════════════════════════════ */
let stagedFiles = [];

function stageFile(input) {
  if (!input.files.length) return;

  for (const file of input.files) {
    if (!file.type.startsWith('image/')) continue; // only images previewed
    stagedFiles.push(file);
    renderStagedPreview(file);
  }

  input.value = ''; // allow re-selecting the same file again later
}

function renderStagedPreview(file) {
  const activeBox = conversationStarted
    ? document.getElementById('bottomInputBox')
    : document.getElementById('centerInputBox');

  if (!activeBox) {
    console.error('renderStagedPreview: target input box not found in DOM');
    return;
  }

  let strip = activeBox.querySelector('.staged-preview-strip');
  if (!strip) {
    strip = document.createElement('div');
    strip.className = 'staged-preview-strip';
    strip.style.display      = 'flex';
    strip.style.gap          = '6px';
    strip.style.flexWrap     = 'wrap';
    strip.style.marginBottom = '6px';
    activeBox.prepend(strip);
  }

  const reader = new FileReader();
  reader.onload = (e) => {
    const wrap = document.createElement('div');
    wrap.style.position = 'relative';
    wrap.style.width    = '56px';
    wrap.style.height   = '56px';

    const img = document.createElement('img');
    img.src                = e.target.result;
    img.style.width        = '100%';
    img.style.height       = '100%';
    img.style.objectFit    = 'cover';
    img.style.borderRadius = '8px';

    const removeBtn = document.createElement('button');
    removeBtn.textContent        = '×';
    removeBtn.style.position     = 'absolute';
    removeBtn.style.top          = '-6px';
    removeBtn.style.right        = '-6px';
    removeBtn.style.width        = '18px';
    removeBtn.style.height       = '18px';
    removeBtn.style.borderRadius = '50%';
    removeBtn.style.border       = 'none';
    removeBtn.style.cursor       = 'pointer';
    removeBtn.onclick = () => {
      stagedFiles = stagedFiles.filter(f => f !== file);
      wrap.remove();
    };

    wrap.appendChild(img);
    wrap.appendChild(removeBtn);
    strip.appendChild(wrap);
  };
  reader.readAsDataURL(file);
}

function clearStagedPreviews() {
  document.querySelectorAll('.staged-preview-strip').forEach(el => el.remove());
  stagedFiles = [];
}

function appendImageMessages(time) {
  stagedFiles.forEach(file => {
    const reader = new FileReader();
    reader.onload = (e) => {
      const row = document.createElement('div');
      row.className = 'msg-row user';

      const bubble = document.createElement('div');
      bubble.className = 'msg-bubble';

      const img = document.createElement('img');
      img.src                = e.target.result;
      img.style.maxWidth     = '220px';
      img.style.borderRadius = '10px';
      img.style.display      = 'block';

      bubble.appendChild(img);

      const ts = document.createElement('span');
      ts.className   = 'msg-time';
      ts.textContent = time;

      row.appendChild(bubble);
      row.appendChild(ts);
      messagesEl.appendChild(row);
      scrollBottom();
    };
    reader.readAsDataURL(file);
  });
  clearStagedPreviews();
}

/* ══════════════════════════════════════════════════════════
   SEND MESSAGE

   FIX: fetch() now has an AbortController timeout. Previously, if
   the backend hung (e.g. the Supabase blocking-call bug in letigo.py,
   or a stuck Ollama generation), this fetch would wait forever with
   no feedback — that's the "typing dots never resolve" bug. Now it
   fails after CHAT_SEND_TIMEOUT_MS with a visible error message
   instead of hanging silently.
══════════════════════════════════════════════════════════ */
async function sendMessage(src) {
  if (streaming) return;

  const inputId = src === 'center' ? 'msgInputCenter' : 'msgInputBottom';
  const input   = document.getElementById(inputId);
  const text    = input.value.trim();

  if (!text && stagedFiles.length === 0) return;

  if (!conversationStarted) startConversation();

  if (!activeId) await createConversation();

  // Guard against the "fake ID" bug: createConversation() falls back to a
  // local_<timestamp> placeholder when the backend is unreachable. That ID
  // is not a valid Supabase UUID — sending it used to fail silently two
  // steps later (inside /chat/send) instead of here, where the user can
  // actually see what went wrong. Stop it before it leaves the browser.
  if (activeId && activeId.startsWith('local_')) {
    appendMessage('bot', 'Error: Could not reach the server to start this conversation. Check your connection and try again.', timestamp());
    streaming = false;
    disableSend(false);
    return;
  }

  const conv = conversations.find(c => c.id === activeId);
  const now  = timestamp();

  if (stagedFiles.length > 0) {
    appendImageMessages(now);
  }

  if (text) {
    conv.messages.push({ role: 'user', text, time: now });
    appendMessage('user', text, now);
  }

  input.value        = '';
  input.style.height = 'auto';
  scrollBottom();

  if (!text) return; // image-only message — nothing to send to backend yet

  if (conv.messages.filter(m => m.role === 'user').length === 1) {
    const title = generateTitle(text);
    conv.title               = title;
    topbarTitle.textContent  = title;
    renderHistory();
    apiFetch(`/chat/conversations/${activeId}/title`, 'PATCH', { title }).catch(() => {});
  }

  const typingRow = appendTyping();
  streaming = true;
  disableSend(true);

  let fullReply = '';

  const controller = new AbortController();
  const timeoutId  = setTimeout(() => controller.abort(), CHAT_SEND_TIMEOUT_MS);

  try {
    const res = await fetch(`${API}/chat/send`, {
      method:  'POST',
      headers: {
        'Content-Type':  'application/json',
        'Authorization': `Bearer ${TOKEN}`,
      },
      body:   JSON.stringify({ conversation_id: activeId, message: text }),
      signal: controller.signal,
    });

    clearTimeout(timeoutId);

    if (!res.ok) {
      const err = await res.json().catch(() => ({}));
      throw new Error(err.detail || `Server error ${res.status}`);
    }

    const reader  = res.body.getReader();
    const decoder = new TextDecoder();
    let botBubble = null;

    while (true) {
      const { done, value } = await reader.read();
      if (done) break;

      const lines = decoder.decode(value).split('\n');

      for (const line of lines) {
        if (!line.startsWith('data:')) continue;
        const raw = line.replace(/^data:\s*/, '').trim();
        if (raw === '[DONE]') break;

        try {
          const parsed = JSON.parse(raw);
          if (parsed.error) throw new Error(parsed.error);

          // token_usage is backend bookkeeping only — never rendered in
          // the chat UI. It's still sent over the stream so the browser
          // receives it (letigo.py uses it server-side to update the
          // user's usage counter), but we just discard it here.
          if (parsed.type === 'token_usage') continue;

          const token = parsed.token || '';
          if (!token) continue;

          fullReply += token;

          if (!botBubble) {
            typingRow.remove();
            const result = appendMessage('bot', '', now);
            botBubble = result.bubble;
          }

          botBubble.textContent = fullReply;
          scrollBottom();

        } catch { /* skip malformed lines */ }
      }
    }

  } catch (err) {
    clearTimeout(timeoutId);
    typingRow.remove();
    const msg = err.name === 'AbortError'
      ? `Request timed out after ${CHAT_SEND_TIMEOUT_MS / 1000}s. The server may be overloaded — try again.`
      : err.message;
    appendMessage('bot', `Error: ${msg}`, timestamp());
  }

  if (fullReply) {
    conv.messages.push({ role: 'bot', text: fullReply, time: timestamp() });
  }

  streaming = false;
  disableSend(false);
  scrollBottom();
}

/* ══════════════════════════════════════════════════════════
   DOM HELPERS
══════════════════════════════════════════════════════════ */
function startConversation() {
  conversationStarted = true;
  centerState.classList.add('hidden');
  messagesEl.classList.add('active');
  inputArea.style.display = 'flex';
  setTimeout(() => document.getElementById('msgInputBottom').focus(), 50);
}

function appendMessage(role, text, time) {
  const row      = document.createElement('div');
  row.className  = `msg-row ${role}`;

  const bubble       = document.createElement('div');
  bubble.className   = 'msg-bubble';
  bubble.textContent = text;

  const ts       = document.createElement('span');
  ts.className   = 'msg-time';
  ts.textContent = time;

  row.appendChild(bubble);
  row.appendChild(ts);
  messagesEl.appendChild(row);
  scrollBottom();
  return { row, bubble };
}

function appendTyping() {
  const row      = document.createElement('div');
  row.className  = 'msg-row bot';

  const bubble       = document.createElement('div');
  bubble.className   = 'msg-bubble typing';
  bubble.innerHTML   =
    '<div class="typing-dot"></div><div class="typing-dot"></div><div class="typing-dot"></div>';

  row.appendChild(bubble);
  messagesEl.appendChild(row);
  scrollBottom();
  return row;
}

function scrollBottom() {
  messagesEl.scrollTop = messagesEl.scrollHeight;
}

function disableSend(on) {
  document.querySelectorAll('.send-btn').forEach(btn => btn.disabled = on);
}

function timestamp() {
  return new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
}

function generateTitle(text) {
  const words = text.trim().split(/\s+/);
  const short = words.slice(0, 6).join(' ');
  return words.length > 6 ? short + '…' : short;
}

function escHtml(t) {
  return String(t)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

/* ══════════════════════════════════════════════════════════
   CONVERSATIONS
══════════════════════════════════════════════════════════ */
async function createConversation() {
  try {
    const data = await apiFetch('/chat/conversations/new', 'POST');
    const conv = { id: data.conversation.id, title: 'New conversation', messages: [] };
    conversations.unshift(conv);
    activeId = conv.id;
    renderHistory();
    return conv;
  } catch {
    const id   = 'local_' + Date.now();
    const conv = { id, title: 'New conversation', messages: [] };
    conversations.unshift(conv);
    activeId = id;
    renderHistory();
    return conv;
  }
}

async function newChat() {
  conversationStarted = false;
  activeId             = null;
  streaming            = false;

  messagesEl.innerHTML = '';
  messagesEl.classList.remove('active');
  inputArea.style.display  = 'none';
  centerState.classList.remove('hidden');
  topbarTitle.textContent  = '';

  clearStagedPreviews();

  ['msgInputCenter', 'msgInputBottom'].forEach(id => {
    const el        = document.getElementById(id);
    el.value        = '';
    el.style.height = 'auto';
  });

  disableSend(false);
  if (isMobile()) closeMobile();

  await createConversation();
}

async function deleteConversation(id, e) {
  e.stopPropagation();

  if (!id.startsWith('local_')) {
    try { await apiFetch(`/chat/conversations/${id}`, 'DELETE'); } catch { /* continue */ }
  }

  conversations = conversations.filter(c => c.id !== id);

  if (activeId === id) {
    await newChat();
  } else {
    renderHistory();
  }
}

function renderHistory() {
  const q = (document.getElementById('searchInput').value || '').toLowerCase();
  historyList.innerHTML = '';

  conversations.forEach(conv => {
    if (q && !conv.title.toLowerCase().includes(q)) return;

    const item     = document.createElement('div');
    item.className = 'history-item' + (conv.id === activeId ? ' active' : '');

    item.innerHTML = `
      <span class="history-item-title">${escHtml(conv.title)}</span>
      <button class="history-delete" title="Delete">
        <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round">
          <polyline points="3 6 5 6 21 6"/>
          <path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6"/>
          <path d="M10 11v6M14 11v6M9 6V4a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2"/>
        </svg>
      </button>`;

    item.querySelector('.history-delete').addEventListener('click', e => deleteConversation(conv.id, e));
    item.addEventListener('click', () => loadConversation(conv.id));
    historyList.appendChild(item);
  });
}

function filterHistory() { renderHistory(); }

/* ══════════════════════════════════════════════════════════
   API HELPER
══════════════════════════════════════════════════════════ */
async function apiFetch(path, method = 'GET', body = null) {
  const opts = {
    method,
    headers: {
      'Content-Type':  'application/json',
      'Authorization': `Bearer ${TOKEN}`,
    },
  };
  if (body) opts.body = JSON.stringify(body);

  const res = await fetch(`${API}${path}`, opts);
  if (!res.ok) {
    const err = await res.json().catch(() => ({}));
    throw new Error(err.detail || `HTTP ${res.status}`);
  }
  return res.json();
}

/* ══════════════════════════════════════════════════════════
   SKELETONS
══════════════════════════════════════════════════════════ */
function showHistorySkeleton() {
  historyList.innerHTML = `
    <div class="skeleton-item">
      <div class="skeleton-line" style="width:82%"></div>
    </div>
    <div class="skeleton-item">
      <div class="skeleton-line" style="width:65%"></div>
    </div>
    <div class="skeleton-item">
      <div class="skeleton-line" style="width:90%"></div>
    </div>
    <div class="skeleton-item">
      <div class="skeleton-line" style="width:55%"></div>
    </div>
    <div class="skeleton-item">
      <div class="skeleton-line" style="width:75%"></div>
    </div>`;
}

function showMsgSkeletons() {
  messagesEl.innerHTML = `
    <div class="msg-skeleton-wrap user">
      <div class="msg-skeleton">
        <div class="skeleton-line" style="width:100%"></div>
      </div>
    </div>
    <div class="msg-skeleton-wrap bot">
      <div class="msg-skeleton">
        <div class="skeleton-line" style="width:100%"></div>
        <div class="skeleton-line" style="width:80%"></div>
        <div class="skeleton-line" style="width:60%"></div>
      </div>
    </div>
    <div class="msg-skeleton-wrap user">
      <div class="msg-skeleton">
        <div class="skeleton-line" style="width:100%"></div>
        <div class="skeleton-line" style="width:70%"></div>
      </div>
    </div>
    <div class="msg-skeleton-wrap bot">
      <div class="msg-skeleton">
        <div class="skeleton-line" style="width:100%"></div>
        <div class="skeleton-line" style="width:88%"></div>
        <div class="skeleton-line" style="width:50%"></div>
      </div>
    </div>`;
}

/* ══════════════════════════════════════════════════════════
   LOAD CONVERSATION
══════════════════════════════════════════════════════════ */
async function loadConversation(id) {
  const conv = conversations.find(c => c.id === id);
  if (!conv) return;

  activeId = id;
  topbarTitle.textContent = conv.title !== 'New conversation' ? conv.title : '';

  if (conv.messages.length === 0 && !id.startsWith('local_')) {
    messagesEl.innerHTML = '';
    conversationStarted   = true;
    centerState.classList.add('hidden');
    messagesEl.classList.add('active');
    inputArea.style.display = 'flex';
    showMsgSkeletons();
    scrollBottom();

    try {
      const data = await apiFetch(`/chat/history/${id}`);
      conv.messages = data.messages.map(m => ({
        role: m.role === 'assistant' ? 'bot' : m.role,
        text: m.content,
        time: new Date(m.created_at).toLocaleTimeString([], {
          hour: '2-digit', minute: '2-digit',
        }),
      }));
    } catch { /* use cached */ }

    messagesEl.innerHTML = '';

    if (conv.messages.length === 0) {
      conversationStarted = false;
      messagesEl.classList.remove('active');
      inputArea.style.display = 'none';
      centerState.classList.remove('hidden');
    } else {
      conv.messages.forEach(m => appendMessage(m.role, m.text, m.time));
      scrollBottom();
    }

  } else if (conv.messages.length > 0) {
    messagesEl.innerHTML = '';
    conversationStarted   = true;
    centerState.classList.add('hidden');
    messagesEl.classList.add('active');
    inputArea.style.display = 'flex';
    conv.messages.forEach(m => appendMessage(m.role, m.text, m.time));
    scrollBottom();
  } else {
    messagesEl.innerHTML = '';
    conversationStarted   = false;
    messagesEl.classList.remove('active');
    inputArea.style.display  = 'none';
    centerState.classList.remove('hidden');
  }

  renderHistory();
  if (isMobile()) closeMobile();
}

/* ══════════════════════════════════════════════════════════
   STARTUP
══════════════════════════════════════════════════════════ */
async function init() {
  showHistorySkeleton();

  try {
    const data = await apiFetch('/chat/conversations');
    conversations = data.conversations.map(c => ({
      id:       c.id,
      title:    c.title,
      messages: [],
    }));
  } catch {
    conversations = [];
  }

  if (conversations.length > 0) {
    renderHistory();
    conversationStarted = true;
    centerState.classList.add('hidden');
    messagesEl.classList.add('active');
    inputArea.style.display = 'flex';
    activeId = conversations[0].id;
    showMsgSkeletons();
    scrollBottom();
    await loadConversation(conversations[0].id);
  } else {
    renderHistory();
    await newChat();
  }
}

init();