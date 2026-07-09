const $ = (selector) => document.querySelector(selector);

const els = {
  sessions: $("#sessions"),
  messages: $("#messages"),
  status: $("#status"),
  sessionTitle: $("#sessionTitle"),
  prompt: $("#prompt"),
  composer: $("#composer"),
  newSession: $("#newSession"),
  renameSession: $("#renameSession"),
  abort: $("#abort"),
  sessionSearch: $("#sessionSearch"),
  openSettings: $("#openSettings"),
  closeSettings: $("#closeSettings"),
  settingsDialog: $("#settingsDialog"),
  modelConfigForm: $("#modelConfigForm"),
  reloadConfig: $("#reloadConfig"),
  defaultProvider: $("#defaultProvider"),
  defaultModel: $("#defaultModel"),
  openaiBaseUrl: $("#openaiBaseUrl"),
  openaiApiKey: $("#openaiApiKey"),
  openaiKeyHint: $("#openaiKeyHint"),
  clearOpenaiApiKey: $("#clearOpenaiApiKey"),
  arealBaseUrl: $("#arealBaseUrl"),
  arealApi: $("#arealApi"),
  arealApiKey: $("#arealApiKey"),
  arealKeyHint: $("#arealKeyHint"),
  bridgeUserId: $("#bridgeUserId"),
  clearArealApiKey: $("#clearArealApiKey"),
};

let state = {};
let sessions = [];
let activeAssistant = null;

function escapeHtml(value) {
  return String(value || "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

async function api(path, options = {}) {
  const response = await fetch(path, {
    headers: { "content-type": "application/json", ...(options.headers || {}) },
    ...options,
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(data.error || `HTTP ${response.status}`);
  return data;
}

function setStatus() {
  const model = state.model ? `${state.model.provider || ""}/${state.model.id || state.model.modelId || ""}` : "未选择模型";
  els.status.textContent = `${state.online ? "已连接" : "离线"} · ${state.isStreaming ? "Pi 正在工作" : "空闲"} · ${model}`;
  els.sessionTitle.textContent = state.sessionName || currentSession()?.firstMessage || "当前会话";
}

function currentSession() {
  return sessions.find((session) => session.path === state.sessionFile);
}

function renderSessions() {
  const query = els.sessionSearch.value.trim().toLowerCase();
  const filtered = sessions.filter((session) => {
    const text = `${session.name || ""} ${session.firstMessage || ""} ${session.cwd || ""}`.toLowerCase();
    return !query || text.includes(query);
  });
  els.sessions.innerHTML = filtered.length ? "" : '<p class="empty">还没有历史会话。</p>';
  for (const session of filtered) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = `session-card${session.path === state.sessionFile ? " active" : ""}`;
    button.innerHTML = `
      <strong>${escapeHtml(session.name || session.firstMessage || "新会话")}</strong>
      <span>${escapeHtml(new Date(session.modified).toLocaleString())} · ${session.messageCount || 0} 条</span>
    `;
    button.addEventListener("click", () => switchSession(session.path));
    els.sessions.appendChild(button);
  }
}

function messageNode(role, text, extraClass) {
  const node = document.createElement("article");
  node.className = `message ${extraClass || role || "event"}`;
  node.innerHTML = `<span class="role">${escapeHtml(role || "event")}</span><div class="text">${escapeHtml(text || "")}</div>`;
  return node;
}

function addMessage(role, text, extraClass) {
  if (!text && role !== "assistant") return null;
  const node = messageNode(role, text, extraClass);
  els.messages.appendChild(node);
  els.messages.scrollTop = els.messages.scrollHeight;
  return node;
}

function appendAssistantDelta(text) {
  if (!activeAssistant) activeAssistant = addMessage("assistant", "", "assistant");
  const body = activeAssistant.querySelector(".text");
  body.textContent += text;
  els.messages.scrollTop = els.messages.scrollHeight;
}

function roleLabel(message) {
  if (message.role === "toolResult") return `tool · ${message.toolName || "result"}`;
  if (message.role === "bashExecution") return `bash · ${message.command || "command"}`;
  return message.role || "event";
}

function renderMessages(messages) {
  els.messages.innerHTML = "";
  activeAssistant = null;
  if (!messages.length) {
    els.messages.innerHTML = '<p class="empty">从这里开始一个 Pi 会话。历史窗口会保留在左侧。</p>';
    return;
  }
  for (const message of messages) {
    const role = roleLabel(message);
    const kind = message.role === "user" || message.role === "assistant" ? message.role : "tool";
    addMessage(role, message.text || message.errorMessage || "", kind);
  }
}

async function loadSessions() {
  const data = await api("/api/sessions");
  sessions = data.sessions || [];
  renderSessions();
  setStatus();
}

async function loadMessages() {
  const data = await api("/api/messages");
  renderMessages(data.messages || []);
}

async function loadState() {
  state = await api("/api/state");
  setStatus();
}

function fillModelConfig(config) {
  els.defaultProvider.value = config.defaultProvider || "openai";
  els.defaultModel.value = config.defaultModel || "";
  els.openaiBaseUrl.value = config.openai?.baseUrl || "";
  els.openaiApiKey.value = "";
  els.openaiKeyHint.textContent = config.openai?.hasApiKey ? `当前 Key：${config.openai.apiKeyMasked}` : "当前未配置 Key";
  els.clearOpenaiApiKey.checked = false;
  els.arealBaseUrl.value = config.areal?.baseUrl || "";
  els.arealApi.value = config.areal?.api || "openai-completions";
  els.arealApiKey.value = "";
  els.arealKeyHint.textContent = config.areal?.hasApiKey ? `当前 Key：${config.areal.apiKeyMasked}` : "当前未配置 Key";
  els.bridgeUserId.value = config.areal?.bridgeUserId || "";
  els.clearArealApiKey.checked = false;
}

async function loadModelConfig() {
  const config = await api("/api/model-config");
  fillModelConfig(config);
  return config;
}

async function openSettings() {
  await loadModelConfig();
  els.settingsDialog.showModal();
}

async function saveModelConfig(event) {
  event.preventDefault();
  const payload = {
    defaultProvider: els.defaultProvider.value,
    defaultModel: els.defaultModel.value,
    openaiBaseUrl: els.openaiBaseUrl.value,
    openaiApiKey: els.openaiApiKey.value,
    clearOpenaiApiKey: els.clearOpenaiApiKey.checked,
    arealBaseUrl: els.arealBaseUrl.value,
    arealApi: els.arealApi.value,
    arealApiKey: els.arealApiKey.value,
    clearArealApiKey: els.clearArealApiKey.checked,
    bridgeUserId: els.bridgeUserId.value,
    restart: true,
  };
  const result = await api("/api/model-config", { method: "POST", body: JSON.stringify(payload) });
  fillModelConfig(result.config);
  addMessage("system", "模型配置已保存，Pi RPC 正在重启以应用新配置。", "event");
  setTimeout(() => Promise.all([loadState(), loadMessages()]).catch(() => {}), 1800);
}

async function switchSession(sessionPath) {
  await api("/api/switch-session", { method: "POST", body: JSON.stringify({ path: sessionPath }) });
  await Promise.all([loadState(), loadSessions(), loadMessages()]);
}

async function createSession() {
  const name = prompt("给新会话起个名字（可留空）", "");
  await api("/api/new-session", { method: "POST", body: JSON.stringify({ name }) });
  renderMessages([]);
  await Promise.all([loadState(), loadSessions()]);
}

async function renameSession() {
  const name = prompt("当前会话名称", state.sessionName || currentSession()?.firstMessage || "");
  if (!name) return;
  await api("/api/session-name", { method: "POST", body: JSON.stringify({ name }) });
  await Promise.all([loadState(), loadSessions()]);
}

async function sendPrompt(event) {
  event.preventDefault();
  const message = els.prompt.value.trim();
  if (!message) return;
  els.prompt.value = "";
  activeAssistant = null;
  if (els.messages.querySelector(".empty")) els.messages.innerHTML = "";
  addMessage("user", message, "user");
  try {
    await api("/api/prompt", { method: "POST", body: JSON.stringify({ message }) });
    await loadSessions();
  } catch (error) {
    addMessage("error", error.message, "stderr");
  }
}

function handleEvent(payload) {
  const { type, data } = payload;
  if (type === "hello") {
    state = data.state || state;
    setStatus();
    return;
  }
  if (type === "state") {
    state = data || {};
    setStatus();
    renderSessions();
    return;
  }
  if (type === "message") {
    if (els.messages.querySelector(".empty")) els.messages.innerHTML = "";
    const kind = data.role === "user" || data.role === "assistant" ? data.role : "tool";
    if (data.role === "assistant" && activeAssistant) {
      activeAssistant = null;
      return;
    }
    if (data.role === "assistant") activeAssistant = null;
    addMessage(roleLabel(data), data.text || data.errorMessage || "", kind);
    return;
  }
  if (type === "delta") {
    if (data.role === "assistant") appendAssistantDelta(data.text || "");
    return;
  }
  if (type === "tool") {
    const label = data.name || data.toolCall?.name || "tool";
    const text = data.args ? JSON.stringify(data.args, null, 2) : data.phase;
    if (data.phase === "execution_start") addMessage(`tool · ${label}`, text, "tool");
    return;
  }
  if (type === "stderr" || type === "error") {
    addMessage(type, data.text || data.message || JSON.stringify(data), "stderr");
  }
  if (type === "event" && (data.type === "agent_end" || data.type === "message_end")) {
    void Promise.all([loadSessions(), loadState()]);
  }
}

function connectEvents() {
  const source = new EventSource("/events");
  source.onmessage = (event) => handleEvent(JSON.parse(event.data));
  source.onerror = () => {
    state.online = false;
    setStatus();
  };
}

els.composer.addEventListener("submit", sendPrompt);
els.newSession.addEventListener("click", () => createSession().catch((error) => addMessage("error", error.message, "stderr")));
els.renameSession.addEventListener("click", () => renameSession().catch((error) => addMessage("error", error.message, "stderr")));
els.abort.addEventListener("click", () => api("/api/abort", { method: "POST" }).catch((error) => addMessage("error", error.message, "stderr")));
els.openSettings.addEventListener("click", () => openSettings().catch((error) => addMessage("error", error.message, "stderr")));
els.closeSettings.addEventListener("click", () => els.settingsDialog.close());
els.reloadConfig.addEventListener("click", () => loadModelConfig().catch((error) => addMessage("error", error.message, "stderr")));
els.modelConfigForm.addEventListener("submit", (event) => saveModelConfig(event).catch((error) => addMessage("error", error.message, "stderr")));
els.sessionSearch.addEventListener("input", renderSessions);
els.prompt.addEventListener("keydown", (event) => {
  if (event.key === "Enter" && !event.shiftKey) {
    event.preventDefault();
    els.composer.requestSubmit();
  }
});

(async function init() {
  connectEvents();
  await Promise.all([loadState(), loadSessions()]).catch((error) => addMessage("error", error.message, "stderr"));
  await loadMessages().catch(() => renderMessages([]));
})();
