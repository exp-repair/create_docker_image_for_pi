(() => {
  const statusEl = document.getElementById("termStatus");
  const reconnectBtn = document.getElementById("reconnect");
  const params = new URLSearchParams(window.location.search);
  const token = params.get("token") || "";

  const term = new Terminal({
    cursorBlink: true,
    fontSize: 14,
    fontFamily: '"IBM Plex Mono", "SF Mono", Menlo, Consolas, monospace',
    theme: {
      background: "#0d141c",
      foreground: "#d7e0ea",
      cursor: "#3dba9a",
      selectionBackground: "rgba(61, 186, 154, 0.28)",
      black: "#0d141c",
      red: "#e08a6a",
      green: "#3dba9a",
      yellow: "#e0c06a",
      blue: "#6ea8d9",
      magenta: "#c792ea",
      cyan: "#7fdbca",
      white: "#d7e0ea",
      brightBlack: "#66788a",
      brightRed: "#ff9b7b",
      brightGreen: "#5fd4b0",
      brightYellow: "#f0d48a",
      brightBlue: "#8cbcf0",
      brightMagenta: "#d7a8ff",
      brightCyan: "#9aefe0",
      brightWhite: "#ffffff",
    },
    allowProposedApi: true,
  });

  const fitAddon = new FitAddon.FitAddon();
  const webLinksAddon = new WebLinksAddon.WebLinksAddon();
  term.loadAddon(fitAddon);
  term.loadAddon(webLinksAddon);
  term.open(document.getElementById("terminal"));

  let socket = null;
  let disposed = false;
  let reconnectTimer = null;

  function setStatus(text, kind) {
    statusEl.textContent = text;
    statusEl.className = `status${kind ? ` ${kind}` : ""}`;
  }

  function proxyBasePath() {
    const path = window.location.pathname;
    const marker = "/term";
    const idx = path.lastIndexOf(marker);
    if (idx <= 0) return "";
    return path.slice(0, idx).replace(/\/+$/, "");
  }

  function wsUrl() {
    const proto = window.location.protocol === "https:" ? "wss:" : "ws:";
    const dims = fitAddon.proposeDimensions() || { cols: term.cols, rows: term.rows };
    const q = new URLSearchParams({
      cols: String(dims.cols || 120),
      rows: String(dims.rows || 30),
    });
    if (token) q.set("token", token);
    return `${proto}//${window.location.host}${proxyBasePath()}/ws/term?${q.toString()}`;
  }

  function sendResize() {
    if (!socket || socket.readyState !== WebSocket.OPEN) return;
    fitAddon.fit();
    socket.send(JSON.stringify({ type: "resize", cols: term.cols, rows: term.rows }));
  }

  function connect() {
    if (disposed) return;
    if (socket) {
      try { socket.close(); } catch { /* ignore */ }
      socket = null;
    }
    if (reconnectTimer) {
      clearTimeout(reconnectTimer);
      reconnectTimer = null;
    }

    setStatus("连接中…");
    fitAddon.fit();
    const ws = new WebSocket(wsUrl());
    socket = ws;

    ws.addEventListener("open", () => {
      setStatus("已连接", "ok");
      sendResize();
    });

    ws.addEventListener("message", (event) => {
      const raw = typeof event.data === "string" ? event.data : "";
      if (raw.startsWith("{")) {
        try {
          const msg = JSON.parse(raw);
          if (msg.type === "ready") {
            setStatus(`${msg.shell} · ${msg.cwd} · pid ${msg.pid}`, "ok");
            return;
          }
          if (msg.type === "exit") {
            setStatus(`进程退出 code=${msg.exitCode ?? "?"} signal=${msg.signal ?? "-"}`, "bad");
            term.writeln("");
            term.writeln(`[session ended] exit=${msg.exitCode ?? "?"} signal=${msg.signal ?? "-"}`);
            return;
          }
          if (msg.type === "error") {
            setStatus(msg.message || "终端错误", "bad");
            term.writeln(`\r\n[error] ${msg.message || "unknown"}`);
            return;
          }
        } catch {
          // treat as terminal output
        }
      }
      term.write(event.data);
    });

    ws.addEventListener("close", () => {
      setStatus("已断开", "bad");
      if (!disposed) {
        reconnectTimer = setTimeout(connect, 1500);
      }
    });

    ws.addEventListener("error", () => {
      setStatus("连接失败", "bad");
    });
  }

  term.onData((data) => {
    if (socket && socket.readyState === WebSocket.OPEN) socket.send(data);
  });

  window.addEventListener("resize", () => sendResize());
  reconnectBtn.addEventListener("click", () => connect());

  document.addEventListener("visibilitychange", () => {
    if (!document.hidden) sendResize();
  });

  connect();
  term.focus();
})();
