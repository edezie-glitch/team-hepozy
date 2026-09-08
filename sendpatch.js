/* ══════════════════════════════════════════════════════════
   REPLACE your sendMessage() function with this version.
   Handles the new orchestrator SSE events:
   reply | instructions | workflow | examples | done
══════════════════════════════════════════════════════════ */

async function sendMessage(src) {
  if (streaming) return;

  const inputId = src === 'center' ? 'msgInputCenter' : 'msgInputBottom';
  const input   = document.getElementById(inputId);
  const text    = input.value.trim();
  if (!text) return;

  if (!conversationStarted) startConversation();
  if (!activeId) await createConversation();

  const conv = conversations.find(c => c.id === activeId);
  const now  = timestamp();

  conv.messages.push({ role: 'user', text, time: now });
  appendMessage('user', text, now);

  input.value = '';
  input.style.height = 'auto';
  scrollBottom();

  // auto-title on first user message
  if (conv.messages.filter(m => m.role === 'user').length === 1) {
    const title = generateTitle(text);
    conv.title  = title;
    topbarTitle.textContent = title;
    renderHistory();
    apiFetch(`/chat/conversations/${activeId}/title`, 'PATCH', { title }).catch(() => {});
  }

  streaming = true;
  disableSend(true);

  // Sections rendered in the chat
  let replyBubble        = null;
  let instructionsBubble = null;
  let workflowBubble     = null;
  let examplesBubble     = null;
  let typingRow          = null;

  function getOrCreateSection(type) {
    const labels = {
      reply:        null,
      instructions: 'Step-by-step instructions',
      workflow:     'Workflow',
      examples:     'Examples',
    };

    const label = labels[type];
    const row   = document.createElement('div');
    row.className = 'msg-row bot';

    if (label) {
      const header     = document.createElement('div');
      header.className = 'msg-section-header';
      header.textContent = label;
      row.appendChild(header);
    }

    const bubble     = document.createElement('div');
    bubble.className = 'msg-bubble';
    row.appendChild(bubble);

    const ts       = document.createElement('span');
    ts.className   = 'msg-time';
    ts.textContent = timestamp();
    row.appendChild(ts);

    messagesEl.appendChild(row);
    scrollBottom();
    return bubble;
  }

  try {
    // remove typing indicator if visible
    if (typingRow) { typingRow.remove(); typingRow = null; }

    // show typing while waiting for first token
    typingRow = appendTyping();

    const res = await fetch(`${API}/chat/send`, {
      method:  'POST',
      headers: {
        'Content-Type':  'application/json',
        'Authorization': `Bearer ${TOKEN}`,
      },
      body: JSON.stringify({ conversation_id: activeId, message: text }),
    });

    if (!res.ok) {
      const err = await res.json().catch(() => ({}));
      throw new Error(err.detail || `Server error ${res.status}`);
    }

    const reader  = res.body.getReader();
    const decoder = new TextDecoder();
    let fullReply = '';

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
          const { type, token } = parsed;

          // remove typing on first real token
          if (typingRow) { typingRow.remove(); typingRow = null; }

          if (type === 'reply' && token) {
            if (!replyBubble) replyBubble = getOrCreateSection('reply');
            fullReply += token;
            replyBubble.textContent = fullReply;
            scrollBottom();
          }

          if (type === 'instructions_start') {
            instructionsBubble = getOrCreateSection('instructions');
          }
          if (type === 'instructions' && token && instructionsBubble) {
            instructionsBubble.textContent += token;
            scrollBottom();
          }

          if (type === 'workflow_start') {
            workflowBubble = getOrCreateSection('workflow');
          }
          if (type === 'workflow' && token && workflowBubble) {
            workflowBubble.textContent += token;
            scrollBottom();
          }

          if (type === 'examples_start') {
            examplesBubble = getOrCreateSection('examples');
          }
          if (type === 'examples' && token && examplesBubble) {
            examplesBubble.textContent += token;
            scrollBottom();
          }

          if (type === 'error') {
            throw new Error(token);
          }

        } catch (e) {
          if (e.message && !e.message.includes('JSON')) throw e;
        }
      }
    }

    if (fullReply) {
      conv.messages.push({ role: 'bot', text: fullReply, time: timestamp() });
    }

  } catch (err) {
    if (typingRow) { typingRow.remove(); typingRow = null; }
    appendMessage('bot', `Error: ${err.message}`, timestamp());
  }

  streaming = false;
  disableSend(false);
  scrollBottom();
}