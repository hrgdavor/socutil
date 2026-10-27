"use strict";

const $ = (id) => document.getElementById(id);
const encoder = new TextEncoder();

// `?transport=sse` uses the tail transport; the default is the WebSocket byte
// tunnel. Both are served by the same binary and tested.
const transport = new URLSearchParams(location.search).get("transport");

const state = {
  /**
   * `name` is the only selector sent to the server; `path` is for display.
   * @type {{id: string, name: string, path: string, kind: "ws" | "sse", source: WebSocket | EventSource, decoder: TextDecoder} | null}
   */
  session: null,
  sockets: [],
};

function setStatus(text, kind = "") {
  const node = $("status");
  node.textContent = text;
  node.className = "status" + (kind ? " " + kind : "");
}

function setInputEnabled(enabled) {
  $("input").disabled = !enabled;
  $("send").disabled = !enabled;
  $("disconnect").disabled = !enabled;
  if (!enabled) $("input").value = "";
}

function appendText(text) {
  const output = $("output");
  if (text.length === 0) return;
  const pinned = output.scrollTop + output.clientHeight >= output.scrollHeight - 12;
  output.append(document.createTextNode(text));
  if (pinned) output.scrollTop = output.scrollHeight;
}

function randomSessionId() {
  if (typeof crypto.randomUUID === "function") return crypto.randomUUID();
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function base64ToBytes(encoded) {
  const binary = atob(encoded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

async function refreshSockets() {
  setStatus("scanning", "busy");
  try {
    const response = await fetch("/api/sockets", { cache: "no-store" });
    if (!response.ok) throw new Error(await response.text());
    const data = await response.json();
    state.sockets = data.sockets || [];
    renderSockets(data.dirs || []);
    setStatus(state.session ? "connected" : "idle", state.session ? "ok" : "");
  } catch (error) {
    console.error(error);
    setStatus("scan failed", "error");
  }
}

function renderSockets(dirs) {
  const list = $("sockets");
  list.replaceChildren();

  for (const socket of state.sockets) {
    const item = document.createElement("li");
    const button = document.createElement("button");
    button.type = "button";
    button.className = "socket";
    button.title = socket.path;
    button.dataset.name = socket.name;
    if (state.session && state.session.name === socket.name) button.classList.add("active");

    const name = document.createElement("span");
    name.className = "socket-name";
    name.textContent = socket.file || socket.name;

    const dir = document.createElement("span");
    dir.className = "socket-dir";
    dir.textContent = socket.dir;

    button.append(name, dir);
    button.addEventListener("click", () => connectTo(socket));
    item.append(button);
    list.append(item);
  }

  $("empty").hidden = state.sockets.length !== 0;
  $("empty").textContent = dirs.length === 0 ? "No directories configured." : "No sockets found.";
}

function connectTo(socket) {
  closeSession(false);
  if (transport === "sse" || typeof WebSocket !== "function") {
    connectTail(socket);
  } else {
    connectTunnel(socket);
  }
}

/**
 * The byte tunnel: binary frames both ways, no handshake envelope and no
 * base64. A frame the server cannot accept (over 64 KiB) closes the session
 * with code 1009 and a "message too big" reason.
 */
function connectTunnel(socket) {
  const id = randomSessionId();
  const params = new URLSearchParams({ id, name: socket.name });
  const scheme = location.protocol === "https:" ? "wss:" : "ws:";
  const source = new WebSocket(scheme + "//" + location.host + "/api/ws?" + params.toString());
  source.binaryType = "arraybuffer";
  const session = {
    id,
    name: socket.name,
    path: socket.path,
    kind: "ws",
    source,
    decoder: new TextDecoder(),
  };
  state.session = session;

  prepareSession(socket);
  setStatus("connecting", "busy");

  source.addEventListener("open", () => {
    if (state.session !== session) return;
    setStatus("connected", "ok");
    setInputEnabled(true);
    $("input").focus();
    appendText("[connected to " + socket.path + "]\n");
  });

  source.addEventListener("message", (event) => {
    if (state.session !== session) return;
    if (typeof event.data === "string") {
      appendText(event.data);
      return;
    }
    appendText(session.decoder.decode(event.data, { stream: true }));
  });

  source.addEventListener("close", (event) => {
    if (state.session !== session) return;
    const reason = event.reason ? ": " + event.reason : "";
    appendText("\n[socket closed" + reason + "]\n");
    closeSession(false);
  });

  source.addEventListener("error", () => {
    if (state.session !== session) return;
    appendText("\n[connection lost]\n");
    closeSession(false);
  });
}

/** The tail transport: SSE down, the handshake command POSTed up. */
function connectTail(socket) {
  const id = randomSessionId();
  const params = new URLSearchParams({ id, name: socket.name });
  const source = new EventSource("/api/events?" + params.toString());
  const session = {
    id,
    name: socket.name,
    path: socket.path,
    kind: "sse",
    source,
    decoder: new TextDecoder(),
  };
  state.session = session;

  prepareSession(socket);
  setStatus("connecting", "busy");

  source.addEventListener("ready", () => {
    if (state.session !== session) return;
    setStatus("connected", "ok");
    setInputEnabled(true);
    $("input").focus();
    appendText("[connected to " + socket.path + "]\n");
  });

  source.addEventListener("out", (event) => {
    if (state.session !== session) return;
    try {
      const payload = JSON.parse(event.data);
      appendText(session.decoder.decode(base64ToBytes(payload.b), { stream: true }));
    } catch (error) {
      console.error("bad output event", error);
    }
  });

  source.addEventListener("exit", (event) => {
    if (state.session !== session) return;
    let reason = "closed";
    try {
      reason = JSON.parse(event.data).reason || reason;
    } catch {
      /* keep the default */
    }
    appendText("\n[socket " + reason + "]\n");
    closeSession(false);
  });

  source.addEventListener("error", () => {
    if (state.session !== session) return;
    appendText("\n[connection lost]\n");
    closeSession(false);
  });
}

function prepareSession(socket) {
  $("output").textContent = "";
  $("target").textContent = socket.path;
  setInputEnabled(false);
  renderSocketsActive();
}

function renderSocketsActive() {
  const buttons = document.querySelectorAll(".socket");
  buttons.forEach((button) => button.classList.remove("active"));
  if (!state.session) return;
  const list = $("sockets").querySelectorAll(".socket");
  list.forEach((button) => {
    if (button.dataset.name === state.session.name) button.classList.add("active");
  });
}

function closeSession(notifyServer = true) {
  const session = state.session;
  if (!session) return;
  state.session = null;

  if (session.kind === "ws") {
    // The close frame is the notification: the server shuts the unix socket
    // down when it arrives, so no POST is needed.
    try {
      session.source.close(1000, "page closed");
    } catch {
      /* already closing */
    }
  } else {
    session.source.close();
    if (notifyServer) {
      fetch("/api/close?" + new URLSearchParams({ id: session.id }).toString(), {
        method: "POST",
      }).catch(() => {});
    }
  }

  setStatus("idle");
  setInputEnabled(false);
  $("target").textContent = "not connected";
  renderSocketsActive();
}

$("refresh").addEventListener("click", refreshSockets);
$("disconnect").addEventListener("click", () => {
  closeSession(true);
  appendText("\n[disconnected]\n");
});

$("input-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  const session = state.session;
  if (!session) return;

  const input = $("input");
  const line = input.value;
  input.value = "";
  const payload = line + "\n";

  if (session.kind === "ws") {
    if (session.source.readyState !== WebSocket.OPEN) {
      appendText("\n[not connected]\n");
      return;
    }
    session.source.send(encoder.encode(payload));
    return;
  }

  try {
    const response = await fetch("/api/input?" + new URLSearchParams({ id: session.id }).toString(), {
      method: "POST",
      headers: { "content-type": "text/plain; charset=utf-8" },
      body: payload,
    });
    if (!response.ok) {
      const detail = (await response.text()).trim();
      appendText("\n[input failed" + (detail ? ": " + detail : "") + "]\n");
    }
  } catch (error) {
    appendText("\n[input failed: " + error.message + "]\n");
  }
});

window.addEventListener("beforeunload", () => {
  const session = state.session;
  if (!session) return;
  if (session.kind === "sse") {
    navigator.sendBeacon("/api/close?" + new URLSearchParams({ id: session.id }).toString());
  } else {
    try {
      session.source.close(1000, "page closed");
    } catch {
      /* already closing */
    }
  }
});

refreshSockets();
