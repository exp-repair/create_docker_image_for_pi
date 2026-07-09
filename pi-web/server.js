#!/usr/bin/env node
"use strict";

const { spawn } = require("node:child_process");
const crypto = require("node:crypto");
const fs = require("node:fs");
const http = require("node:http");
const path = require("node:path");

const HOST = process.env.PI_WEB_HOST || "0.0.0.0";
const PORT = Number(process.env.PI_WEB_PORT || 6079);
const WORKSPACE_DIR = process.env.PI_WEB_WORKSPACE || process.env.PI_WORKSPACE_DIR || "/workspace";
const PI_BIN = process.env.PI_BIN || "pi";
const PUBLIC_DIR = path.join(__dirname, "public");
const AGENT_DIR = process.env.PI_AGENT_DIR || path.join(process.env.HOME || "/home/user", ".pi", "agent");
const SESSIONS_ROOT = path.join(AGENT_DIR, "sessions");
const MODELS_FILE = path.join(AGENT_DIR, "models.json");
const SETTINGS_FILE = path.join(AGENT_DIR, "settings.json");

const clients = new Set();
const pending = new Map();
const eventLog = [];
const MAX_EVENTS = 500;
let rpc = null;
let rpcBuffer = "";
let starting = false;
let resumeSessionFile = null;
let state = {
  online: false,
  isStreaming: false,
  sessionFile: null,
  sessionId: null,
  sessionName: null,
  model: null,
  messageCount: 0,
  pendingMessageCount: 0,
};

function json(res, status, data) {
  const body = JSON.stringify(data);
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(body),
  });
  res.end(body);
}

function notFound(res) {
  json(res, 404, { error: "Not found" });
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let body = "";
    req.setEncoding("utf8");
    req.on("data", (chunk) => {
      body += chunk;
      if (body.length > 2 * 1024 * 1024) {
        reject(new Error("Request body too large"));
        req.destroy();
      }
    });
    req.on("end", () => {
      if (!body) return resolve({});
      try {
        resolve(JSON.parse(body));
      } catch {
        reject(new Error("Invalid JSON body"));
      }
    });
    req.on("error", reject);
  });
}

function safeSessionPath(sessionPath) {
  if (!sessionPath || typeof sessionPath !== "string") return null;
  const resolved = path.resolve(sessionPath);
  const root = path.resolve(SESSIONS_ROOT);
  return (resolved === root || resolved.startsWith(`${root}${path.sep}`)) && resolved.endsWith(".jsonl") ? resolved : null;
}

function readJsonFile(filePath) {
  try {
    return fs.existsSync(filePath) ? JSON.parse(fs.readFileSync(filePath, "utf8")) : {};
  } catch {
    return {};
  }
}

function writeJsonFile(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`);
}

function maskSecret(value) {
  if (!value) return "";
  const text = String(value);
  if (text.length <= 8) return "********";
  return `${text.slice(0, 4)}...${text.slice(-4)}`;
}

function getModelConfig() {
  const models = readJsonFile(MODELS_FILE);
  const settings = readJsonFile(SETTINGS_FILE);
  const providers = models.providers && typeof models.providers === "object" ? models.providers : {};
  const openai = providers.openai && typeof providers.openai === "object" ? providers.openai : {};
  const areal = models.areal && typeof models.areal === "object" ? models.areal : {};
  const arealHeaders = areal.headers && typeof areal.headers === "object" ? areal.headers : {};
  return {
    defaultProvider: settings.defaultProvider || "openai",
    defaultModel: settings.defaultModel || "",
    openai: {
      baseUrl: openai.baseUrl || "",
      hasApiKey: Boolean(openai.apiKey),
      apiKeyMasked: maskSecret(openai.apiKey),
    },
    areal: {
      baseUrl: areal.baseUrl || "",
      api: areal.api || "openai-completions",
      hasApiKey: Boolean(areal.apiKey),
      apiKeyMasked: maskSecret(areal.apiKey),
      bridgeUserId: arealHeaders["X-Bridge-User-Id"] || "",
    },
  };
}

function saveModelConfig(body) {
  const models = readJsonFile(MODELS_FILE);
  const settings = readJsonFile(SETTINGS_FILE);
  const providers = models.providers && typeof models.providers === "object" ? models.providers : {};
  const openai = providers.openai && typeof providers.openai === "object" ? providers.openai : {};
  const areal = models.areal && typeof models.areal === "object" ? models.areal : {};

  const nextOpenai = { ...openai };
  if (body.openaiBaseUrl !== undefined) nextOpenai.baseUrl = String(body.openaiBaseUrl).trim();
  if (body.openaiApiKey !== undefined && String(body.openaiApiKey).trim()) nextOpenai.apiKey = String(body.openaiApiKey).trim();
  if (body.clearOpenaiApiKey) delete nextOpenai.apiKey;
  providers.openai = nextOpenai;

  const nextAreal = { ...areal };
  if (body.arealBaseUrl !== undefined) nextAreal.baseUrl = String(body.arealBaseUrl).trim();
  if (body.arealApi !== undefined) nextAreal.api = String(body.arealApi).trim() || "openai-completions";
  if (body.arealApiKey !== undefined && String(body.arealApiKey).trim()) nextAreal.apiKey = String(body.arealApiKey).trim();
  if (body.clearArealApiKey) delete nextAreal.apiKey;
  const headers = nextAreal.headers && typeof nextAreal.headers === "object" ? nextAreal.headers : {};
  if (body.bridgeUserId !== undefined) headers["X-Bridge-User-Id"] = String(body.bridgeUserId).trim();
  nextAreal.headers = headers;

  models.providers = providers;
  models.areal = nextAreal;
  if (body.defaultProvider !== undefined) settings.defaultProvider = String(body.defaultProvider).trim() || "openai";
  if (body.defaultModel !== undefined) settings.defaultModel = String(body.defaultModel).trim();

  writeJsonFile(MODELS_FILE, models);
  writeJsonFile(SETTINGS_FILE, settings);
  return getModelConfig();
}

function sendSse(res, payload) {
  res.write(`data: ${JSON.stringify(payload)}\n\n`);
}

function broadcast(type, data) {
  const payload = { type, data, at: Date.now() };
  eventLog.push(payload);
  if (eventLog.length > MAX_EVENTS) eventLog.shift();
  for (const res of clients) sendSse(res, payload);
}

function summarizeText(content) {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .filter((block) => block && block.type === "text")
    .map((block) => block.text || "")
    .join("");
}

function normalizeMessage(message) {
  if (!message || typeof message !== "object") return null;
  if (message.role === "assistant") {
    return {
      role: "assistant",
      text: summarizeText(message.content),
      content: message.content || [],
      model: message.model,
      provider: message.provider,
      timestamp: message.timestamp,
      stopReason: message.stopReason,
      errorMessage: message.errorMessage,
    };
  }
  if (message.role === "user") {
    return { role: "user", text: summarizeText(message.content), timestamp: message.timestamp };
  }
  if (message.role === "toolResult") {
    return {
      role: "toolResult",
      toolName: message.toolName,
      text: summarizeText(message.content),
      isError: Boolean(message.isError),
      timestamp: message.timestamp,
    };
  }
  if (message.role === "bashExecution") {
    return {
      role: "bashExecution",
      command: message.command,
      text: message.output || "",
      exitCode: message.exitCode,
      cancelled: message.cancelled,
      timestamp: message.timestamp,
    };
  }
  if (message.role === "custom") {
    return { role: "custom", customType: message.customType, text: summarizeText(message.content), timestamp: message.timestamp };
  }
  if (message.role === "compactionSummary") {
    return { role: "compactionSummary", text: message.summary || "", timestamp: message.timestamp };
  }
  return { role: message.role || "unknown", text: summarizeText(message.content), timestamp: message.timestamp };
}

function setState(next) {
  state = { ...state, ...next };
  broadcast("state", state);
}

function handleRpcRecord(record) {
  if (record.type === "response" && record.id && pending.has(record.id)) {
    const { resolve, timeout } = pending.get(record.id);
    clearTimeout(timeout);
    pending.delete(record.id);
    resolve(record);
  }

  if (record.type === "response" && record.command === "get_state" && record.success) {
    setState({ online: true, ...pickState(record.data || {}) });
  } else if (record.type === "agent_start") {
    setState({ isStreaming: true });
  } else if (record.type === "agent_end") {
    setState({ isStreaming: false });
    void refreshState();
  } else if (record.type === "queue_update") {
    void refreshState();
  }

  if (record.type === "message_end") {
    const message = normalizeMessage(record.message);
    if (message && message.role !== "user") broadcast("message", message);
  } else if (record.type === "message_update") {
    const delta = record.assistantMessageEvent || {};
    if (delta.type === "text_delta" && delta.delta) {
      broadcast("delta", { role: "assistant", text: delta.delta });
    } else if (delta.type === "thinking_delta" && delta.delta) {
      broadcast("delta", { role: "thinking", text: delta.delta });
    } else if (delta.type === "toolcall_start") {
      broadcast("tool", { phase: "start", toolCall: delta.toolCall || delta.partial });
    } else if (delta.type === "toolcall_end") {
      broadcast("tool", { phase: "end", toolCall: delta.toolCall });
    }
  } else if (record.type === "tool_execution_start") {
    broadcast("tool", { phase: "execution_start", name: record.toolName, args: record.args, id: record.toolCallId });
  } else if (record.type === "tool_execution_update") {
    broadcast("tool", { phase: "execution_update", name: record.toolName, result: record.partialResult, id: record.toolCallId });
  } else if (record.type === "tool_execution_end") {
    broadcast("tool", { phase: "execution_end", name: record.toolName, result: record.result, id: record.toolCallId });
  } else if (record.type && record.type !== "message_update") {
    broadcast("event", record);
  }
}

function pickState(data) {
  return {
    isStreaming: Boolean(data.isStreaming),
    sessionFile: data.sessionFile || null,
    sessionId: data.sessionId || null,
    sessionName: data.sessionName || null,
    model: data.model || null,
    messageCount: data.messageCount || 0,
    pendingMessageCount: data.pendingMessageCount || 0,
  };
}

function startRpc() {
  if (rpc || starting) return;
  starting = true;
  const args = ["--mode", "rpc"];
  if (resumeSessionFile && safeSessionPath(resumeSessionFile) && fs.existsSync(resumeSessionFile)) args.push("--session", resumeSessionFile);
  if (process.env.PI_WEB_PI_ARGS) args.push(...process.env.PI_WEB_PI_ARGS.split(/\s+/).filter(Boolean));
  if (process.env.PI_WEB_SESSION_DIR) args.push("--session-dir", process.env.PI_WEB_SESSION_DIR);
  rpc = spawn(PI_BIN, args, {
    cwd: WORKSPACE_DIR,
    env: { ...process.env, HOME: process.env.HOME || "/home/user", PI_SKIP_VERSION_CHECK: process.env.PI_SKIP_VERSION_CHECK || "1" },
    stdio: ["pipe", "pipe", "pipe"],
  });

  rpc.stdout.setEncoding("utf8");
  rpc.stdout.on("data", (chunk) => {
    rpcBuffer += chunk;
    let index;
    while ((index = rpcBuffer.indexOf("\n")) !== -1) {
      const line = rpcBuffer.slice(0, index).replace(/\r$/, "");
      rpcBuffer = rpcBuffer.slice(index + 1);
      if (!line.trim()) continue;
      try {
        handleRpcRecord(JSON.parse(line));
      } catch (error) {
        broadcast("error", { message: "Failed to parse Pi RPC output", detail: error.message, line });
      }
    }
  });

  rpc.stderr.setEncoding("utf8");
  rpc.stderr.on("data", (chunk) => broadcast("stderr", { text: chunk }));
  rpc.on("spawn", () => {
    starting = false;
    setState({ online: true });
    void refreshState();
  });
  rpc.on("exit", (code, signal) => {
    rpc = null;
    starting = false;
    for (const [id, item] of pending) {
      clearTimeout(item.timeout);
      item.reject(new Error(`Pi RPC exited before response ${id}`));
    }
    pending.clear();
    setState({ online: false, isStreaming: false });
    broadcast("error", { message: "Pi RPC process exited", code, signal });
    setTimeout(startRpc, 1500);
  });
}

function restartRpc() {
  resumeSessionFile = safeSessionPath(state.sessionFile) || null;
  if (rpc) {
    rpc.kill("SIGTERM");
  } else {
    startRpc();
  }
}

function rpcCommand(command, timeoutMs = 120000) {
  startRpc();
  if (!rpc || !rpc.stdin.writable) return Promise.reject(new Error("Pi RPC is not ready"));
  const id = crypto.randomUUID();
  const payload = { id, ...command };
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      pending.delete(id);
      reject(new Error(`Timed out waiting for ${command.type}`));
    }, timeoutMs);
    pending.set(id, { resolve, reject, timeout });
    rpc.stdin.write(`${JSON.stringify(payload)}\n`, (error) => {
      if (error) {
        clearTimeout(timeout);
        pending.delete(id);
        reject(error);
      }
    });
  });
}

async function refreshState() {
  try {
    const result = await rpcCommand({ type: "get_state" }, 15000);
    if (result.success) setState({ online: true, ...pickState(result.data || {}) });
  } catch (error) {
    broadcast("error", { message: "Unable to refresh Pi state", detail: error.message });
  }
}

function parseSessionFile(filePath) {
  const lines = fs.readFileSync(filePath, "utf8").split("\n").filter(Boolean);
  let header = null;
  let name;
  let firstMessage = "";
  let messageCount = 0;
  let modified = 0;
  for (const line of lines) {
    let entry;
    try {
      entry = JSON.parse(line);
    } catch {
      continue;
    }
    if (entry.type === "session") {
      header = entry;
      modified = Math.max(modified, Date.parse(entry.timestamp) || 0);
      continue;
    }
    modified = Math.max(modified, Date.parse(entry.timestamp) || 0);
    if (entry.type === "session_info") name = (entry.name || "").trim() || undefined;
    if (entry.type !== "message" || !entry.message) continue;
    if (entry.message.role === "user" || entry.message.role === "assistant") messageCount++;
    if (!firstMessage && entry.message.role === "user") firstMessage = summarizeText(entry.message.content).trim();
  }
  if (!header) return null;
  const stats = fs.statSync(filePath);
  return {
    id: header.id,
    name,
    path: filePath,
    cwd: header.cwd || "",
    created: header.timestamp,
    modified: new Date(modified || stats.mtimeMs).toISOString(),
    messageCount,
    firstMessage: firstMessage || "新会话",
  };
}

function listSessionFiles(dir) {
  if (!fs.existsSync(dir)) return [];
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, entry.name);
    if (entry.isDirectory()) out.push(...listSessionFiles(p));
    else if (entry.isFile() && entry.name.endsWith(".jsonl")) out.push(p);
  }
  return out;
}

async function handleApi(req, res, url) {
  try {
    if (req.method === "GET" && url.pathname === "/api/state") return json(res, 200, state);
    if (req.method === "GET" && url.pathname === "/api/model-config") return json(res, 200, getModelConfig());
    if (req.method === "POST" && url.pathname === "/api/model-config") {
      const body = await readBody(req);
      const config = saveModelConfig(body);
      if (body.restart !== false) restartRpc();
      broadcast("model_config", config);
      return json(res, 200, { success: true, config, restarted: body.restart !== false });
    }
    if (req.method === "GET" && url.pathname === "/api/sessions") {
      const sessions = listSessionFiles(SESSIONS_ROOT)
        .map((file) => {
          try { return parseSessionFile(file); } catch { return null; }
        })
        .filter(Boolean)
        .sort((a, b) => new Date(b.modified) - new Date(a.modified));
      return json(res, 200, { sessions });
    }
    if (req.method === "GET" && url.pathname === "/api/messages") {
      const result = await rpcCommand({ type: "get_messages" }, 30000);
      const messages = ((result.data && result.data.messages) || []).map(normalizeMessage).filter(Boolean);
      return json(res, result.success ? 200 : 500, { success: result.success, messages, error: result.error });
    }
    if (req.method === "POST" && url.pathname === "/api/prompt") {
      const body = await readBody(req);
      const message = String(body.message || "").trim();
      if (!message) return json(res, 400, { error: "Message is required" });
      const command = { type: "prompt", message };
      if (state.isStreaming) command.streamingBehavior = body.streamingBehavior || "steer";
      const result = await rpcCommand(command, 30000);
      return json(res, result.success ? 200 : 500, result);
    }
    if (req.method === "POST" && url.pathname === "/api/new-session") {
      const body = await readBody(req);
      const result = await rpcCommand({ type: "new_session" }, 30000);
      if (result.success && body.name) await rpcCommand({ type: "set_session_name", name: String(body.name).trim() }, 30000);
      await refreshState();
      return json(res, result.success ? 200 : 500, result);
    }
    if (req.method === "POST" && url.pathname === "/api/switch-session") {
      const body = await readBody(req);
      const sessionPath = safeSessionPath(body.path);
      if (!sessionPath) return json(res, 400, { error: "Invalid session path" });
      const result = await rpcCommand({ type: "switch_session", sessionPath }, 30000);
      await refreshState();
      return json(res, result.success ? 200 : 500, result);
    }
    if (req.method === "POST" && url.pathname === "/api/session-name") {
      const body = await readBody(req);
      const name = String(body.name || "").trim();
      if (!name) return json(res, 400, { error: "Name is required" });
      const result = await rpcCommand({ type: "set_session_name", name }, 30000);
      await refreshState();
      return json(res, result.success ? 200 : 500, result);
    }
    if (req.method === "POST" && url.pathname === "/api/abort") {
      const result = await rpcCommand({ type: "abort" }, 30000);
      return json(res, result.success ? 200 : 500, result);
    }
    return notFound(res);
  } catch (error) {
    return json(res, 500, { error: error.message });
  }
}

function serveStatic(req, res, url) {
  let file = url.pathname === "/" ? "index.html" : decodeURIComponent(url.pathname.slice(1));
  file = path.normalize(file).replace(/^([.][.][/\\])+/, "");
  const fullPath = path.join(PUBLIC_DIR, file);
  if (!fullPath.startsWith(PUBLIC_DIR) || !fs.existsSync(fullPath) || fs.statSync(fullPath).isDirectory()) return notFound(res);
  const ext = path.extname(fullPath).toLowerCase();
  const types = { ".html": "text/html; charset=utf-8", ".css": "text/css; charset=utf-8", ".js": "application/javascript; charset=utf-8", ".svg": "image/svg+xml" };
  res.writeHead(200, { "content-type": types[ext] || "application/octet-stream" });
  fs.createReadStream(fullPath).pipe(res);
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || "localhost"}`);
  if (url.pathname === "/events") {
    res.writeHead(200, {
      "content-type": "text/event-stream; charset=utf-8",
      "cache-control": "no-cache, no-transform",
      connection: "keep-alive",
    });
    clients.add(res);
    sendSse(res, { type: "hello", data: { state }, at: Date.now() });
    req.on("close", () => clients.delete(res));
    return;
  }
  if (url.pathname.startsWith("/api/")) return void handleApi(req, res, url);
  serveStatic(req, res, url);
});

startRpc();
server.listen(PORT, HOST, () => {
  console.log(`[pi-web] listening on http://${HOST}:${PORT}`);
  console.log(`[pi-web] workspace=${WORKSPACE_DIR} sessions=${SESSIONS_ROOT}`);
});
