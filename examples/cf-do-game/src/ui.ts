export function renderGameHtml(): string {
  return `<!doctype html>
<html lang="ja">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <title>Converge Survivors</title>
  <style>
    :root {
      --bg-0: #05070f;
      --bg-1: #0f1a2d;
      --bg-2: #13263a;
      --ink: #eaf5ff;
      --ink-subtle: #96b6cc;
      --accent: #6fffe8;
      --danger: #ff4f6d;
      --card: rgba(8, 14, 24, 0.72);
      --line: rgba(145, 191, 220, 0.18);
      --shadow: 0 20px 70px rgba(0, 0, 0, 0.45);
    }

    * {
      box-sizing: border-box;
    }

    html, body {
      margin: 0;
      width: 100%;
      height: 100%;
      overflow: hidden;
      color: var(--ink);
      font-family: "Avenir Next", "Trebuchet MS", "Segoe UI", sans-serif;
      background:
        radial-gradient(1200px 800px at 10% -20%, #1f3d6f 0%, transparent 65%),
        radial-gradient(900px 700px at 120% 100%, #2f224d 0%, transparent 60%),
        linear-gradient(160deg, var(--bg-0) 0%, var(--bg-1) 50%, var(--bg-2) 100%);
    }

    #app {
      position: fixed;
      inset: 0;
      opacity: 0;
      animation: fade-in 420ms ease-out forwards;
    }

    #game {
      position: fixed;
      inset: 0;
      width: 100%;
      height: 100%;
      display: block;
      touch-action: none;
    }

    #topbar {
      position: fixed;
      top: 12px;
      left: 50%;
      transform: translateX(-50%);
      display: flex;
      gap: 8px;
      align-items: center;
      padding: 8px 10px;
      border: 1px solid var(--line);
      border-radius: 12px;
      background: var(--card);
      backdrop-filter: blur(8px);
      box-shadow: var(--shadow);
      z-index: 10;
    }

    #topbar input[type="text"] {
      width: 180px;
      border-radius: 8px;
      border: 1px solid var(--line);
      background: rgba(7, 10, 18, 0.8);
      color: var(--ink);
      padding: 6px 8px;
      font-size: 13px;
    }

    #topbar input[type="color"] {
      width: 34px;
      height: 34px;
      padding: 0;
      border: 1px solid var(--line);
      border-radius: 8px;
      background: transparent;
    }

    #topbar button {
      border: 1px solid rgba(117, 251, 228, 0.4);
      background: linear-gradient(160deg, rgba(111, 255, 232, 0.2), rgba(111, 255, 232, 0.1));
      color: var(--ink);
      border-radius: 8px;
      padding: 7px 10px;
      font-weight: 600;
      cursor: pointer;
    }

    .hud {
      position: fixed;
      top: 12px;
      z-index: 10;
      min-width: 220px;
      border: 1px solid var(--line);
      border-radius: 12px;
      background: var(--card);
      backdrop-filter: blur(8px);
      box-shadow: var(--shadow);
      padding: 10px 12px;
    }

    #hud-left {
      left: 12px;
    }

    #hud-right {
      right: 12px;
      width: 260px;
    }

    .label {
      font-size: 11px;
      letter-spacing: 0.08em;
      text-transform: uppercase;
      color: var(--ink-subtle);
      margin-bottom: 6px;
    }

    #status {
      font-weight: 700;
      margin-bottom: 8px;
      font-size: 13px;
    }

    #stats {
      font-size: 13px;
      line-height: 1.4;
      white-space: pre-line;
    }

    #leaderboard {
      margin: 0;
      padding-left: 20px;
      max-height: 280px;
      overflow: auto;
      font-size: 13px;
      line-height: 1.5;
    }

    #hint {
      position: fixed;
      bottom: max(12px, env(safe-area-inset-bottom));
      left: 50%;
      transform: translateX(-50%);
      padding: 8px 12px;
      border-radius: 999px;
      border: 1px solid var(--line);
      background: var(--card);
      backdrop-filter: blur(8px);
      font-size: 12px;
      color: var(--ink-subtle);
      z-index: 10;
      text-align: center;
    }

    @media (max-width: 840px) {
      #topbar {
        width: calc(100% - 16px);
        left: 8px;
        transform: none;
        justify-content: space-between;
      }

      #topbar input[type="text"] {
        width: 46vw;
      }

      .hud {
        top: auto;
        bottom: calc(56px + env(safe-area-inset-bottom));
      }

      #hud-left {
        left: 8px;
        min-width: 44vw;
      }

      #hud-right {
        right: 8px;
        width: 44vw;
      }
    }

    @keyframes fade-in {
      from {
        opacity: 0;
        transform: translateY(8px);
      }
      to {
        opacity: 1;
        transform: translateY(0);
      }
    }
  </style>
</head>
<body>
  <div id="app">
    <canvas id="game"></canvas>

    <div id="topbar">
      <input id="name" type="text" maxlength="24" spellcheck="false">
      <input id="color" type="color">
      <button id="apply">Apply</button>
    </div>

    <div id="hud-left" class="hud">
      <div class="label">Session</div>
      <div id="status">Connecting...</div>
      <div id="stats"></div>
    </div>

    <div id="hud-right" class="hud">
      <div class="label">Leaderboard</div>
      <ol id="leaderboard"></ol>
    </div>

    <div id="hint">WASD/矢印キーで移動。モバイルは画面左ドラッグで移動。敵に触れないよう生存してレベルを上げる。</div>
  </div>

  <script>
  (() => {
    const WORLD_DEFAULT = { width: 2200, height: 1320, tick_ms: 50 };
    const PLAYER_SPEED = 310;
    const SEND_INTERVAL_MS = 50;
    const initialDebugMode = (() => {
      const mode = new URLSearchParams(location.search).get("debug");
      if (!mode) return false;
      const normalized = mode.toLowerCase();
      return normalized === "1" || normalized === "true" || normalized === "on";
    })();

    const canvas = document.getElementById("game");
    const ctx = canvas.getContext("2d");
    const statusEl = document.getElementById("status");
    const statsEl = document.getElementById("stats");
    const leaderboardEl = document.getElementById("leaderboard");
    const nameInput = document.getElementById("name");
    const colorInput = document.getElementById("color");
    const applyButton = document.getElementById("apply");
    const hintEl = document.getElementById("hint");

    const randomId = () => Math.random().toString(36).slice(2, 10);
    const randomColor = () => {
      const hue = Math.floor(Math.random() * 360);
      return hslToHex(hue, 78, 60);
    };

    let peerId = randomId();
    let playerName = localStorage.getItem("converge_name") || ("Hunter-" + Math.floor(Math.random() * 900 + 100));
    let playerColor = localStorage.getItem("converge_color") || randomColor();

    nameInput.value = playerName;
    colorInput.value = playerColor;

    let ws = null;
    let pingTimer = null;
    let reconnectTimer = null;
    let worldMeta = { ...WORLD_DEFAULT };
    let worldState = { tick: 0, elapsedMs: 0, players: {}, enemies: [], online: 0 };

    let localX = worldMeta.width / 2;
    let localY = worldMeta.height / 2;

    let lastFrameAt = performance.now();
    let lastSendAt = 0;
    let inputSeq = 0;
    let pingSentAt = 0;
    let rttMs = 0;
    let lastConnError = "";
    let connectAttempts = 0;
    let connectTimeout = null;
    let debugMode = initialDebugMode;

    const keys = new Set();
    const pointer = {
      active: false,
      id: -1,
      startX: 0,
      startY: 0,
      dx: 0,
      dy: 0,
    };

    function setStatus(text, online) {
      const mode = debugMode ? " | debug:on" : "";
      const suffix = lastConnError ? " | " + lastConnError : "";
      statusEl.textContent = text + " | online=" + online + mode + suffix;
    }

    function connect() {
      if (ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)) return;

      clearTimeout(reconnectTimer);
      if (connectTimeout) {
        clearTimeout(connectTimeout);
        connectTimeout = null;
      }
      const proto = location.protocol === "https:" ? "wss" : "ws";
      const debugQs = debugMode ? "&debug=1" : "";
      const url = proto + "://" + location.host + "/ws?room=main&peer_id=" + encodeURIComponent(peerId) + debugQs;
      connectAttempts += 1;
      setStatus("Connecting#" + connectAttempts, worldState.online);

      try {
        ws = new WebSocket(url);
      } catch (error) {
        lastConnError = "websocket init failed";
        setStatus("InitError", worldState.online);
        reconnectTimer = setTimeout(connect, 1200);
        return;
      }

      connectTimeout = setTimeout(() => {
        if (!ws || ws.readyState === WebSocket.OPEN) return;
        lastConnError = "connect timeout";
        try { ws.close(); } catch {}
        reconnectTimer = setTimeout(connect, 900);
      }, 5000);

      ws.addEventListener("open", () => {
        lastConnError = "";
        if (connectTimeout) {
          clearTimeout(connectTimeout);
          connectTimeout = null;
        }
        setStatus("Connected", worldState.online);

        if (pingTimer) clearInterval(pingTimer);
        pingTimer = setInterval(() => {
          if (!ws || ws.readyState !== WebSocket.OPEN) return;
          pingSentAt = performance.now();
          ws.send(JSON.stringify({ type: "ping", t: Date.now() }));
        }, 2000);
      });

      ws.addEventListener("message", (event) => {
        try {
          const msg = JSON.parse(String(event.data));

          if (msg.type === "welcome") {
            if (typeof msg.peer_id === "string" && msg.peer_id.length > 0) {
              peerId = msg.peer_id;
            }
            if (msg.world && typeof msg.world.width === "number" && typeof msg.world.height === "number") {
              worldMeta = msg.world;
            }
            return;
          }

          if (msg.type === "game_state" && msg.state) {
            worldState = msg.state;
            const me = worldState.players[peerId];
            if (me) {
              localX += (me.x - localX) * 0.32;
              localY += (me.y - localY) * 0.32;
            }
            return;
          }

          if (msg.type === "pong") {
            rttMs = Math.round(performance.now() - pingSentAt);
          }
        } catch {
          // ignore malformed frames
        }
      });

      ws.addEventListener("close", () => {
        if (connectTimeout) {
          clearTimeout(connectTimeout);
          connectTimeout = null;
        }
        setStatus("Reconnecting", worldState.online);
        if (pingTimer) {
          clearInterval(pingTimer);
          pingTimer = null;
        }
        reconnectTimer = setTimeout(connect, 900);
      });

      ws.addEventListener("error", (event) => {
        lastConnError = event && event.message ? String(event.message) : "ws error";
        setStatus("Error", worldState.online);
      });
    }

    function applyProfile() {
      const nextName = nameInput.value.trim().slice(0, 24);
      if (nextName.length > 0) {
        playerName = nextName;
        localStorage.setItem("converge_name", playerName);
      }
      if (/^#[0-9a-fA-F]{6}$/.test(colorInput.value)) {
        playerColor = colorInput.value;
        localStorage.setItem("converge_color", playerColor);
      }
    }

    function movementVector() {
      let vx = 0;
      let vy = 0;

      if (keys.has("up")) vy -= 1;
      if (keys.has("down")) vy += 1;
      if (keys.has("left")) vx -= 1;
      if (keys.has("right")) vx += 1;

      vx += pointer.dx;
      vy += pointer.dy;

      const len = Math.hypot(vx, vy);
      if (len > 1) {
        vx /= len;
        vy /= len;
      }
      return { vx, vy };
    }

    function sendInput(now) {
      if (!ws || ws.readyState !== WebSocket.OPEN) return;
      if (now - lastSendAt < SEND_INTERVAL_MS) return;
      lastSendAt = now;
      inputSeq += 1;
      const ts = inputSeq;

      const entries = {
        input_x: {
          [peerId]: {
            key: peerId,
            value: localX,
            timestamp: ts,
            peer: peerId,
          },
        },
        input_y: {
          [peerId]: {
            key: peerId,
            value: localY,
            timestamp: ts,
            peer: peerId,
          },
        },
        input_name: {
          [peerId]: {
            key: peerId,
            value: playerName,
            timestamp: ts,
            peer: peerId,
          },
        },
        input_color: {
          [peerId]: {
            key: peerId,
            value: playerColor,
            timestamp: ts,
            peer: peerId,
          },
        },
      };

      ws.send(JSON.stringify({ type: "state", entries }));
    }

    function update(dt, now) {
      const v = movementVector();
      localX = clamp(localX + v.vx * PLAYER_SPEED * dt, 0, worldMeta.width);
      localY = clamp(localY + v.vy * PLAYER_SPEED * dt, 0, worldMeta.height);
      sendInput(now);
    }

    function draw(now) {
      const dpr = Math.min(2, Math.max(1, window.devicePixelRatio || 1));
      const width = Math.floor(window.innerWidth * dpr);
      const height = Math.floor(window.innerHeight * dpr);
      if (canvas.width !== width || canvas.height !== height) {
        canvas.width = width;
        canvas.height = height;
      }
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);

      const vw = window.innerWidth;
      const vh = window.innerHeight;
      const me = worldState.players[peerId];
      const focusX = me ? me.x : localX;
      const focusY = me ? me.y : localY;

      const cameraX = focusX - vw / 2;
      const cameraY = focusY - vh / 2;

      ctx.clearRect(0, 0, vw, vh);
      drawBackground(vw, vh, now);
      drawGrid(vw, vh, cameraX, cameraY);
      drawAuras(cameraX, cameraY);
      drawEnemies(cameraX, cameraY);
      drawPlayers(cameraX, cameraY);
      drawJoystick();
      drawPlayerArrow(vw, vh, me);

      updateHud();
    }

    function drawBackground(vw, vh, now) {
      const bg = ctx.createLinearGradient(0, 0, vw, vh);
      bg.addColorStop(0, "#081425");
      bg.addColorStop(1, "#10253b");
      ctx.fillStyle = bg;
      ctx.fillRect(0, 0, vw, vh);

      const pulse = 0.08 + 0.04 * Math.sin(now * 0.001);
      ctx.fillStyle = "rgba(140, 212, 255," + pulse.toFixed(3) + ")";
      ctx.beginPath();
      ctx.arc(vw * 0.85, vh * 0.2, 180, 0, Math.PI * 2);
      ctx.fill();
    }

    function drawGrid(vw, vh, cameraX, cameraY) {
      const spacing = 60;
      ctx.strokeStyle = "rgba(160, 195, 218, 0.15)";
      ctx.lineWidth = 1;
      ctx.beginPath();

      const startX = Math.floor(cameraX / spacing) * spacing - cameraX;
      const startY = Math.floor(cameraY / spacing) * spacing - cameraY;

      for (let x = startX; x < vw; x += spacing) {
        ctx.moveTo(x, 0);
        ctx.lineTo(x, vh);
      }
      for (let y = startY; y < vh; y += spacing) {
        ctx.moveTo(0, y);
        ctx.lineTo(vw, y);
      }
      ctx.stroke();
    }

    function drawAuras(cameraX, cameraY) {
      for (const player of Object.values(worldState.players)) {
        if (!player.alive) continue;
        const sx = player.x - cameraX;
        const sy = player.y - cameraY;

        ctx.beginPath();
        ctx.arc(sx, sy, player.auraRadius, 0, Math.PI * 2);
        ctx.strokeStyle = player.peerId === peerId ? "rgba(111,255,232,0.30)" : "rgba(140,210,255,0.18)";
        ctx.lineWidth = player.peerId === peerId ? 2 : 1;
        ctx.stroke();
      }
    }

    function drawEnemies(cameraX, cameraY) {
      for (const enemy of worldState.enemies) {
        const sx = enemy.x - cameraX;
        const sy = enemy.y - cameraY;

        ctx.beginPath();
        ctx.arc(sx, sy, 9, 0, Math.PI * 2);
        ctx.fillStyle = "#ff4f6d";
        ctx.fill();

        const ratio = clamp(enemy.hp / Math.max(1, enemy.maxHp), 0, 1);
        ctx.fillStyle = "rgba(12,16,22,0.8)";
        ctx.fillRect(sx - 12, sy - 16, 24, 3);
        ctx.fillStyle = "#ffc2cb";
        ctx.fillRect(sx - 12, sy - 16, 24 * ratio, 3);

        if (debugMode) {
          const tag = enemy.kind ? String(enemy.kind).slice(0, 1).toUpperCase() : "E";
          ctx.fillStyle = "rgba(255, 230, 235, 0.95)";
          ctx.font = "10px 'Avenir Next', 'Trebuchet MS', sans-serif";
          ctx.textAlign = "center";
          ctx.fillText(tag, sx, sy + 3);
        }
      }
    }

    function drawPlayers(cameraX, cameraY) {
      for (const player of Object.values(worldState.players)) {
        const sx = player.x - cameraX;
        const sy = player.y - cameraY;
        const alpha = player.alive ? 1 : 0.45;

        ctx.beginPath();
        ctx.arc(sx, sy, 12, 0, Math.PI * 2);
        ctx.fillStyle = hexToRgba(player.color, alpha);
        ctx.fill();

        if (player.peerId === peerId) {
          ctx.beginPath();
          ctx.arc(sx, sy, 18, 0, Math.PI * 2);
          ctx.strokeStyle = "rgba(255,255,255,0.9)";
          ctx.lineWidth = 2;
          ctx.stroke();
        }

        const hpRatio = clamp(player.hp / Math.max(1, player.maxHp), 0, 1);
        ctx.fillStyle = "rgba(12, 16, 22, 0.8)";
        ctx.fillRect(sx - 16, sy - 22, 32, 4);
        ctx.fillStyle = hpRatio > 0.4 ? "#7eff9c" : "#ff8b9b";
        ctx.fillRect(sx - 16, sy - 22, 32 * hpRatio, 4);

        ctx.fillStyle = "rgba(235, 245, 255, 0.95)";
        ctx.font = "12px 'Avenir Next', 'Trebuchet MS', sans-serif";
        ctx.textAlign = "center";
        ctx.fillText(player.name + " Lv" + player.level, sx, sy + 28);
      }
    }

    function drawPlayerArrow(vw, vh, me) {
      if (!me || me.alive) return;

      ctx.fillStyle = "rgba(255, 126, 144, 0.9)";
      ctx.font = "700 15px 'Avenir Next', 'Trebuchet MS', sans-serif";
      ctx.textAlign = "center";
      ctx.fillText("Respawning...", vw / 2, vh / 2 - 24);
    }

    function drawJoystick() {
      if (!pointer.active) return;

      ctx.save();
      ctx.globalAlpha = 0.86;

      ctx.beginPath();
      ctx.arc(pointer.startX, pointer.startY, 46, 0, Math.PI * 2);
      ctx.fillStyle = "rgba(18, 30, 44, 0.45)";
      ctx.fill();
      ctx.strokeStyle = "rgba(176, 220, 244, 0.44)";
      ctx.lineWidth = 2;
      ctx.stroke();

      const knobX = pointer.startX + pointer.dx * 28;
      const knobY = pointer.startY + pointer.dy * 28;
      ctx.beginPath();
      ctx.arc(knobX, knobY, 18, 0, Math.PI * 2);
      ctx.fillStyle = "rgba(111, 255, 232, 0.82)";
      ctx.fill();

      ctx.restore();
    }

    function updateHud() {
      const me = worldState.players[peerId];
      const seconds = Math.floor(worldState.elapsedMs / 1000);
      const mm = String(Math.floor(seconds / 60)).padStart(2, "0");
      const ss = String(seconds % 60).padStart(2, "0");

      let statText = "Time " + mm + ":" + ss + "\\n";
      statText += "Ping " + rttMs + "ms\\n";
      statText += "Enemies " + worldState.enemies.length + "\\n";
      statText += "Local " + Math.round(localX) + "," + Math.round(localY) + "\\n";

      if (me) {
        statText += "Server " + Math.round(me.x) + "," + Math.round(me.y) + "\\n";
        const hp = Math.max(0, Math.round(me.hp));
        statText += "HP " + hp + "/" + me.maxHp + "\\n";
        statText += "Level " + me.level + "  XP " + me.xp + "/" + me.xpToNext + "\\n";
        statText += "Score " + me.score + "  Aura " + me.auraDps + " DPS";
      } else {
        statText += "Spawning...";
      }
      if (debugMode && worldState.debug) {
        const d = worldState.debug;
        statText += "\\nDBG spawn " + d.spawnedEnemies + " (" + d.spawnBudgetLeft.toFixed(2) + "/" + d.spawnBudgetStart.toFixed(2) + ")";
        statText += "\\nDBG aura c=" + d.auraCandidates + " h=" + d.auraHits;
        statText += "\\nDBG touch " + d.touchHits + " cells " + d.spatialCells;
        statText += "\\nDBG step " + d.tickComputeMs + "ms";
      }

      statsEl.textContent = statText;
      setStatus(ws && ws.readyState === WebSocket.OPEN ? "Connected" : "Connecting", worldState.online || 0);

      const ranking = Object.values(worldState.players)
        .slice()
        .sort((a, b) => {
          if (b.score !== a.score) return b.score - a.score;
          if (b.level !== a.level) return b.level - a.level;
          return b.xp - a.xp;
        })
        .slice(0, 8);

      leaderboardEl.innerHTML = ranking.map((p) => {
        const marker = p.peerId === peerId ? "<strong>YOU</strong> " : "";
        const alive = p.alive ? "" : " (down)";
        return "<li>" + marker + escapeHtml(p.name) + " Lv" + p.level + " / " + p.score + " kills" + alive + "</li>";
      }).join("");
    }

    function tick(now) {
      const dt = Math.min(0.05, (now - lastFrameAt) / 1000);
      lastFrameAt = now;
      update(dt, now);
      draw(now);
      requestAnimationFrame(tick);
    }

    function setupEvents() {
      applyButton.addEventListener("click", () => {
        applyProfile();
      });

      nameInput.addEventListener("keydown", (event) => {
        if (event.key === "Enter") {
          applyProfile();
        }
      });

      window.addEventListener("keydown", (event) => {
        if (event.code === "Backquote") {
          debugMode = !debugMode;
          const url = new URL(location.href);
          if (debugMode) {
            url.searchParams.set("debug", "1");
          } else {
            url.searchParams.delete("debug");
          }
          history.replaceState(null, "", url.toString());
          setStatus("Reconnect", worldState.online || 0);
          if (ws) {
            try { ws.close(); } catch {}
          }
          return;
        }
        const dir = normalizeDirectionKey(event);
        if (dir) {
          keys.add(dir);
        }
        if (isControlKey(event)) {
          event.preventDefault();
        }
      }, { passive: false, capture: true });

      window.addEventListener("keyup", (event) => {
        const dir = normalizeDirectionKey(event);
        if (dir) {
          keys.delete(dir);
        }
      }, { capture: true });

      window.addEventListener("blur", () => {
        keys.clear();
      });

      canvas.addEventListener("pointerdown", (event) => {
        if (event.clientX > window.innerWidth * 0.52) return;
        pointer.active = true;
        pointer.id = event.pointerId;
        pointer.startX = event.clientX;
        pointer.startY = event.clientY;
        pointer.dx = 0;
        pointer.dy = 0;
      });

      canvas.addEventListener("pointermove", (event) => {
        if (!pointer.active || event.pointerId !== pointer.id) return;
        const dx = event.clientX - pointer.startX;
        const dy = event.clientY - pointer.startY;
        const mag = Math.hypot(dx, dy);
        if (mag <= 1) {
          pointer.dx = 0;
          pointer.dy = 0;
          return;
        }
        const max = 54;
        pointer.dx = clamp(dx / max, -1, 1);
        pointer.dy = clamp(dy / max, -1, 1);
      });

      const clearPointer = (event) => {
        if (!pointer.active || event.pointerId !== pointer.id) return;
        pointer.active = false;
        pointer.id = -1;
        pointer.dx = 0;
        pointer.dy = 0;
      };

      canvas.addEventListener("pointerup", clearPointer);
      canvas.addEventListener("pointercancel", clearPointer);
    }

    function clamp(v, min, max) {
      return Math.min(max, Math.max(min, v));
    }

    function normalizeDirectionKey(event) {
      const key = String(event.key || "");
      const code = String(event.code || "");
      const k = key.toLowerCase();
      const c = code.toLowerCase();

      if (k === "arrowup" || c === "arrowup" || k === "w" || c === "keyw") return "up";
      if (k === "arrowdown" || c === "arrowdown" || k === "s" || c === "keys") return "down";
      if (k === "arrowleft" || c === "arrowleft" || k === "a" || c === "keya") return "left";
      if (k === "arrowright" || c === "arrowright" || k === "d" || c === "keyd") return "right";
      return null;
    }

    function isControlKey(event) {
      const key = String(event.key || "");
      const code = String(event.code || "");
      if (key === " " || code === "Space") return true;
      return normalizeDirectionKey(event) !== null;
    }

    function hslToHex(h, s, l) {
      s /= 100;
      l /= 100;
      const c = (1 - Math.abs(2 * l - 1)) * s;
      const x = c * (1 - Math.abs((h / 60) % 2 - 1));
      const m = l - c / 2;
      let r = 0;
      let g = 0;
      let b = 0;
      if (h < 60) {
        r = c; g = x; b = 0;
      } else if (h < 120) {
        r = x; g = c; b = 0;
      } else if (h < 180) {
        r = 0; g = c; b = x;
      } else if (h < 240) {
        r = 0; g = x; b = c;
      } else if (h < 300) {
        r = x; g = 0; b = c;
      } else {
        r = c; g = 0; b = x;
      }
      const toHex = (n) => Math.round((n + m) * 255).toString(16).padStart(2, "0");
      return "#" + toHex(r) + toHex(g) + toHex(b);
    }

    function hexToRgba(hex, alpha) {
      if (!/^#[0-9a-fA-F]{6}$/.test(hex)) return "rgba(180,210,240," + alpha + ")";
      const r = parseInt(hex.slice(1, 3), 16);
      const g = parseInt(hex.slice(3, 5), 16);
      const b = parseInt(hex.slice(5, 7), 16);
      return "rgba(" + r + "," + g + "," + b + "," + alpha + ")";
    }

    function escapeHtml(text) {
      return text
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;")
        .replace(/\"/g, "&quot;")
        .replace(/'/g, "&#039;");
    }

    setupEvents();
    if (hintEl && debugMode) {
      hintEl.textContent = hintEl.textContent + " | Debug: ON (Backquote キーで切替)";
    }
    connect();
    requestAnimationFrame(tick);
  })();
  </script>
</body>
</html>`;
}
