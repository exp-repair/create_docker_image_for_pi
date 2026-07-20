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
  addProvider: $("#addProvider"),
  providersList: $("#providersList"),
  defaultProvider: $("#defaultProvider"),
  defaultModel: $("#defaultModel"),
  theme: $("#theme"),
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
let activeThinking = null;
let providersDraft = [];
let stickToBottom = true;

function escapeHtml(value) {
  return String(value || "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function isNearBottom(el, threshold = 80) {
  return el.scrollHeight - el.scrollTop - el.clientHeight <= threshold;
}

function scrollMessagesToBottom(force = false) {
  if (!force && !stickToBottom) return;
  requestAnimationFrame(() => {
    els.messages.scrollTop = els.messages.scrollHeight;
  });
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

function thinkingNode(text) {
  const node = document.createElement("article");
  node.className = "message thinking";
  node.innerHTML = `
    <details>
      <summary>思考过程</summary>
      <div class="text">${escapeHtml(text || "")}</div>
    </details>
  `;
  return node;
}

function collapsibleProcessNode(role, text, extraClass) {
  const node = document.createElement("article");
  node.className = `message ${extraClass || role || "event"}`;
  node.innerHTML = `
    <details>
      <summary>${escapeHtml(role || "process")}</summary>
      <div class="text">${escapeHtml(text || "")}</div>
    </details>
  `;
  return node;
}

function messageNode(role, text, extraClass) {
  if (extraClass === "thinking" || role === "thinking") return thinkingNode(text);
  if (extraClass === "tool" || extraClass === "event" || role === "toolResult" || role === "bashExecution") {
    return collapsibleProcessNode(role, text, extraClass === "tool" || extraClass === "event" ? extraClass : "tool");
  }
  const node = document.createElement("article");
  node.className = `message ${extraClass || role || "event"}`;
  node.innerHTML = `<span class="role">${escapeHtml(role || "event")}</span><div class="text">${escapeHtml(text || "")}</div>`;
  return node;
}

function addMessage(role, text, extraClass) {
  if (!text && role !== "assistant" && role !== "thinking") return null;
  const node = messageNode(role, text, extraClass);
  els.messages.appendChild(node);
  scrollMessagesToBottom();
  return node;
}

function appendAssistantDelta(text) {
  if (!activeAssistant) activeAssistant = addMessage("assistant", "", "assistant");
  const body = activeAssistant.querySelector(".text");
  body.textContent += text;
  scrollMessagesToBottom();
}

function appendThinkingDelta(text) {
  if (!text) return;
  if (!activeThinking) {
    activeThinking = thinkingNode("");
    els.messages.appendChild(activeThinking);
  }
  const body = activeThinking.querySelector(".text");
  body.textContent += text;
  const summary = activeThinking.querySelector("summary");
  if (summary) summary.textContent = "思考过程（点击展开）";
  scrollMessagesToBottom();
}

function roleLabel(message) {
  if (message.role === "toolResult") return `tool · ${message.toolName || "result"}`;
  if (message.role === "bashExecution") return `bash · ${message.command || "command"}`;
  return message.role || "event";
}

function renderMessages(messages) {
  els.messages.innerHTML = "";
  activeAssistant = null;
  activeThinking = null;
  stickToBottom = true;
  if (!messages.length) {
    els.messages.innerHTML = '<p class="empty">从这里开始一个 Pi 会话。历史窗口会保留在左侧。</p>';
    return;
  }
  for (const message of messages) {
    if (message.thinking) addMessage("thinking", message.thinking, "thinking");
    const role = roleLabel(message);
    const kind = message.role === "user" || message.role === "assistant" ? message.role : "tool";
    addMessage(role, message.text || message.errorMessage || "", kind);
  }
  scrollMessagesToBottom(true);
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

function syncProviderDraftFromDom() {
  const cards = [...els.providersList.querySelectorAll(".provider-card")];
  providersDraft = cards.map((card) => {
    const index = Number(card.dataset.index);
    const prev = providersDraft[index] || {};
    return {
      name: card.querySelector('[data-field="name"]').value.trim(),
      baseUrl: card.querySelector('[data-field="baseUrl"]').value.trim(),
      api: card.querySelector('[data-field="api"]').value.trim(),
      models: card.querySelector('[data-field="models"]').value.trim(),
      apiKey: card.querySelector('[data-field="apiKey"]').value,
      clearApiKey: card.querySelector('[data-field="clearApiKey"]').checked,
      hasApiKey: prev.hasApiKey,
      apiKeyMasked: prev.apiKeyMasked || "",
      builtin: prev.builtin,
    };
  });
}

function refreshDefaultProviderOptions(selected) {
  const names = providersDraft.map((item) => item.name.trim()).filter(Boolean);
  const current = selected || els.defaultProvider.value || "";
  const options = [...new Set(names)];
  if (current && !options.includes(current)) options.unshift(current);
  els.defaultProvider.innerHTML = options.length
    ? options.map((name) => `<option value="${escapeHtml(name)}">${escapeHtml(name)}</option>`).join("")
    : '<option value="">（暂无 provider）</option>';
  if (current && options.includes(current)) els.defaultProvider.value = current;
  else if (options.length) els.defaultProvider.value = options[0];
}

function renderProviders() {
  if (!providersDraft.length) {
    els.providersList.innerHTML = '<p class="hint providers-empty">还没有 Provider，点击右上角「添加 Provider」。</p>';
    refreshDefaultProviderOptions();
    return;
  }
  els.providersList.innerHTML = "";
  providersDraft.forEach((provider, index) => {
    const card = document.createElement("article");
    card.className = "provider-card";
    card.dataset.index = String(index);
    const keyHint = provider.hasApiKey
      ? `当前 Key：${provider.apiKeyMasked || "********"}`
      : "当前未配置 Key";
    const modelsValue = Array.isArray(provider.models) ? provider.models.join(", ") : (provider.models || "");
    card.innerHTML = `
      <div class="provider-card-head">
        <strong>Provider #${index + 1}${provider.builtin ? " · builtin" : " · custom"}</strong>
        <button type="button" class="ghost danger" data-action="remove">删除</button>
      </div>
      <label>名称
        <input data-field="name" value="${escapeHtml(provider.name || "")}" placeholder="openai / zai-coding-cn" required pattern="[A-Za-z0-9._-]+">
      </label>
      <label>Base URL
        <input data-field="baseUrl" value="${escapeHtml(provider.baseUrl || "")}" placeholder="https://api.example.com/v1">
      </label>
      <label>API 类型
        <input data-field="api" value="${escapeHtml(provider.api || "")}" placeholder="openai-completions（自定义 provider 必填）">
      </label>
      <label>Models（逗号分隔 model id）
        <input data-field="models" value="${escapeHtml(modelsValue)}" placeholder="glm-5.2, glm-4.6（注意带连字符）">
      </label>
      <label>API Key
        <input data-field="apiKey" type="password" autocomplete="new-password" value="${escapeHtml(provider.apiKey || "")}" placeholder="留空则保持不变">
        <span class="hint">${escapeHtml(keyHint)}</span>
      </label>
      <label class="checkline">
        <input data-field="clearApiKey" type="checkbox"${provider.clearApiKey ? " checked" : ""}>
        清空此 Key
      </label>
    `;
    card.querySelector('[data-action="remove"]').addEventListener("click", () => {
      syncProviderDraftFromDom();
      providersDraft.splice(index, 1);
      renderProviders();
    });
    card.querySelector('[data-field="name"]').addEventListener("input", () => {
      syncProviderDraftFromDom();
      refreshDefaultProviderOptions(els.defaultProvider.value);
    });
    els.providersList.appendChild(card);
  });
  refreshDefaultProviderOptions();
}

function fillModelConfig(config) {
  providersDraft = (config.providers || []).map((item) => ({
    name: item.name || "",
    baseUrl: item.baseUrl || "",
    api: item.api || "",
    models: item.models || [],
    apiKey: "",
    clearApiKey: false,
    hasApiKey: Boolean(item.hasApiKey),
    apiKeyMasked: item.apiKeyMasked || "",
    builtin: Boolean(item.builtin),
  }));
  renderProviders();
  els.defaultProvider.value = config.defaultProvider || els.defaultProvider.value || "";
  refreshDefaultProviderOptions(config.defaultProvider || "");
  els.defaultModel.value = config.defaultModel || "";
  const theme = config.theme || "light";
  if (![...els.theme.options].some((opt) => opt.value === theme)) {
    const option = document.createElement("option");
    option.value = theme;
    option.textContent = theme;
    els.theme.appendChild(option);
  }
  els.theme.value = theme;
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

function collectProvidersPayload() {
  syncProviderDraftFromDom();
  const seen = new Set();
  const providers = [];
  for (const item of providersDraft) {
    const name = item.name.trim();
    if (!name) throw new Error("Provider 名称不能为空");
    if (!/^[A-Za-z0-9._-]+$/.test(name)) throw new Error(`Provider 名称非法: ${name}`);
    if (seen.has(name)) throw new Error(`重复的 Provider: ${name}`);
    seen.add(name);
    providers.push({
      name,
      baseUrl: item.baseUrl.trim(),
      api: item.api.trim(),
      models: item.models,
      apiKey: item.apiKey,
      clearApiKey: Boolean(item.clearApiKey),
    });
  }
  return providers;
}

async function saveModelConfig(event) {
  event.preventDefault();
  const providers = collectProvidersPayload();
  const payload = {
    defaultProvider: els.defaultProvider.value,
    defaultModel: els.defaultModel.value,
    theme: els.theme.value,
    providers,
    arealBaseUrl: els.arealBaseUrl.value,
    arealApi: els.arealApi.value,
    arealApiKey: els.arealApiKey.value,
    clearArealApiKey: els.clearArealApiKey.checked,
    bridgeUserId: els.bridgeUserId.value,
    restart: true,
  };
  const result = await api("/api/model-config", { method: "POST", body: JSON.stringify(payload) });
  fillModelConfig(result.config);
  const active = result.currentModel || result.modelApplied;
  const activeLabel = active ? `${active.provider || ""}/${active.id || active.modelId || ""}` : "未知";
  if (result.applyError) {
    addMessage("error", `配置已保存，但切换模型失败：${result.applyError}`, "stderr");
  } else {
    addMessage("system", `模型配置已保存，当前模型：${activeLabel}`, "event");
  }
  await Promise.all([loadState(), loadMessages()]).catch(() => {});
}

async function switchSession(sessionPath) {
  stickToBottom = true;
  await api("/api/switch-session", { method: "POST", body: JSON.stringify({ path: sessionPath }) });
  await Promise.all([loadState(), loadSessions(), loadMessages()]);
}

async function createSession() {
  const name = prompt("给新会话起个名字（可留空）", "");
  stickToBottom = true;
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
  activeThinking = null;
  stickToBottom = true;
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
    if (data.thinking) {
      activeThinking = null;
      addMessage("thinking", data.thinking, "thinking");
    }
    const kind = data.role === "user" || data.role === "assistant" ? data.role : "tool";
    if (data.role === "assistant" && activeAssistant) {
      activeAssistant = null;
      activeThinking = null;
      return;
    }
    if (data.role === "assistant") {
      activeAssistant = null;
      activeThinking = null;
    }
    addMessage(roleLabel(data), data.text || data.errorMessage || "", kind);
    return;
  }
  if (type === "delta") {
    if (data.role === "assistant") appendAssistantDelta(data.text || "");
    else if (data.role === "thinking") appendThinkingDelta(data.text || "");
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
    activeThinking = null;
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
els.addProvider.addEventListener("click", () => {
  syncProviderDraftFromDom();
  providersDraft.push({
    name: "",
    baseUrl: "",
    api: "openai-completions",
    models: [],
    apiKey: "",
    clearApiKey: false,
    hasApiKey: false,
    apiKeyMasked: "",
    builtin: false,
  });
  renderProviders();
  const last = els.providersList.querySelector(".provider-card:last-child [data-field='name']");
  if (last) last.focus();
});
els.modelConfigForm.addEventListener("submit", (event) => saveModelConfig(event).catch((error) => addMessage("error", error.message, "stderr")));
els.sessionSearch.addEventListener("input", renderSessions);
els.messages.addEventListener("scroll", () => {
  stickToBottom = isNearBottom(els.messages);
});
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
  scrollMessagesToBottom(true);
})();
