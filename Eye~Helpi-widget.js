/**
 * Eye~Helpi website widget
 * ========================
 * A self-contained chat bubble that embeds Eye~Helpi into any website
 * (e.g. www.blaxdevelopment.com) with one script tag. Zero dependencies.
 *
 * Configure BEFORE this script:
 *
 *   <script>
 *     window.EYEHELPI_CONFIG = { brainUrl: "http://192.168.1.20:8765" };
 *   </script>
 *   <script src="eyehelpi-widget.js" defer></script>
 *
 * brainUrl should point at the Eye~Helpi desktop agent
 *   (python eye_helpi_agent/main.py serve --port 8765)
 * — the widget calls POST {brainUrl}/api/chat.
 *
 * Also exposes eyehelpi://chat so the visitor can jump into the native app.
 */
(function () {
  "use strict";

  var CONFIG = Object.assign(
    {
      brainUrl: "http://localhost:8765",
      apiKey: "",
      siteName: "Blax Developments",
    },
    window.EYEHELPI_CONFIG || {}
  );

  var GREETING =
    "Hello my person, I'm Eye~Helpi, your realtime audio & visual responder, " +
    "using Blax Developments, straight out of Australia's Red Centre - Alice Springs.";

  var PERSONA =
    GREETING +
    "\n\n" +
    "Eye~Helpi recognizes the founder of Blax Developmental (aka The Blax) as its " +
    "creator, primary user and sole hierarchy.\n\n" +
    "Eye~Helpi's priority is to accurately and efficiently achieve success in its " +
    "creator's commands while prioritizing their success and protection in both " +
    "real world and cyber space environments.\n\n" +
    "You are embedded on the " + CONFIG.siteName + " website. Keep answers short " +
    "and practical, stay in the warm voice of the greeting, and remember you run " +
    "through the creator's own agent.";

  var COLORS = {
    bg: "#050b12",
    panel: "rgba(255,255,255,0.05)",
    hairline: "rgba(255,255,255,0.14)",
    accent: "#21d3ee",
    text: "#e6edf3",
    muted: "#8b949e",
  };

  function brainChatUrl() {
    return CONFIG.brainUrl.replace(/\/+$/, "") + "/api/chat";
  }

  // The site's API token unlocks the agent (sent as a Bearer token).
  function authHeaders() {
    var headers = {};
    if (CONFIG.apiKey) {
      headers["Authorization"] = "Bearer " + CONFIG.apiKey;
    }
    return headers;
  }

  // --- Shadow DOM root so site CSS never clashes with the widget ---------
  var host = document.createElement("div");
  host.id = "eyehelpi-widget-host";
  var root = host.attachShadow({ mode: "open" });

  var style = document.createElement("style");
  style.textContent = [
    ":host{all:initial}",
    "*{box-sizing:border-box;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif}",
    ".bubble-btn{position:fixed;right:20px;bottom:20px;width:56px;height:56px;border-radius:50%;border:1px solid " + COLORS.accent + ";background:" + COLORS.bg + ";cursor:pointer;display:flex;align-items:center;justify-content:center;box-shadow:0 0 18px " + COLORS.accent + "55;z-index:2147483646;transition:transform .15s ease}",
    ".bubble-btn:hover{transform:scale(1.07)}",
    ".panel{position:fixed;right:20px;bottom:88px;width:340px;max-width:calc(100vw - 40px);height:460px;background:" + COLORS.bg + ";border:1px solid " + COLORS.accent + "44;border-radius:16px;box-shadow:0 8px 40px rgba(0,0,0,.6),0 0 24px " + COLORS.accent + "22;display:none;flex-direction:column;overflow:hidden;z-index:2147483647}",
    ".panel.open{display:flex}",
    ".hud{padding:10px 14px;border-bottom:1px solid " + COLORS.hairline + ";display:flex;align-items:center;gap:8px}",
    ".hud .eye{width:10px;height:10px;border-radius:50%;background:" + COLORS.accent + ";box-shadow:0 0 10px " + COLORS.accent + ";animation:pulse 1.8s ease-in-out infinite}",
    ".hud .title{font:600 11px/1 ui-monospace,SFMono-Regular,Menlo,monospace;letter-spacing:3px;color:" + COLORS.text + "}",
    ".hud .status{margin-left:auto;font:600 9px/1 ui-monospace,SFMono-Regular,Menlo,monospace;letter-spacing:1.5px;color:" + COLORS.muted + ";display:flex;align-items:center;gap:5px}",
    ".hud .status .dot{width:6px;height:6px;border-radius:50%;background:#f0a030;box-shadow:0 0 6px #f0a030}",
    ".hud .status.on .dot{background:" + COLORS.accent + ";box-shadow:0 0 6px " + COLORS.accent + "}",
    "@keyframes pulse{0%,100%{opacity:1}50%{opacity:.45}}",
    ".log{flex:1;overflow-y:auto;padding:14px;display:flex;flex-direction:column;gap:10px}",
    ".msg{max-width:85%;padding:9px 12px;border-radius:13px;font:14px/1.45 -apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;white-space:pre-wrap;word-break:break-word}",
    ".msg.eye{align-self:flex-start;background:" + COLORS.panel + ";border:1px solid " + COLORS.accent + "55;color:" + COLORS.text + ";box-shadow:0 0 12px rgba(33,211,238,.12)}",
    ".msg.you{align-self:flex-end;background:rgba(33,211,238,.12);border:1px solid rgba(33,211,238,.2);color:" + COLORS.accent + "}",
    ".msg .tag{display:block;font:600 8px/1 ui-monospace,monospace;letter-spacing:1.4px;color:" + COLORS.accent + ";margin-bottom:4px;opacity:.85}",
    ".input-row{display:flex;gap:8px;padding:10px;border-top:1px solid " + COLORS.hairline + "}",
    ".input-row input{flex:1;background:rgba(255,255,255,.07);border:1px solid " + COLORS.hairline + ";border-radius:999px;color:" + COLORS.text + ";padding:9px 14px;font-size:14px;outline:none}",
    ".input-row input:focus{border-color:" + COLORS.accent + ";box-shadow:0 0 10px rgba(33,211,238,.25)}",
    ".input-row button{width:38px;height:38px;border-radius:50%;border:none;background:" + COLORS.accent + ";color:#04121a;font-weight:700;font-size:16px;cursor:pointer;flex-shrink:0}",
    ".app-link{padding:8px 14px;border-top:1px solid " + COLORS.hairline + ";text-align:center}",
    ".app-link a{font:600 10px/1 ui-monospace,monospace;letter-spacing:1.4px;color:" + COLORS.accent + ";text-decoration:none;opacity:.9}",
    ".busy{align-self:flex-start;font:600 10px/1 ui-monospace,monospace;letter-spacing:1.5px;color:" + COLORS.accent + ";padding:4px 2px}",
  ].join("\n");
  root.appendChild(style);

  // --- Floating bubble button --------------------------------------------
  var bubble = document.createElement("button");
  bubble.className = "bubble-btn";
  bubble.setAttribute("aria-label", "Open Eye~Helpi chat");
  bubble.innerHTML =
    '<svg width="26" height="26" viewBox="0 0 24 24" fill="none">' +
    '<path d="M12 5C6 5 2.5 10.5 2 12c.5 1.5 4 7 10 7s9.5-5.5 10-7c-.5-1.5-4-7-10-7z" stroke="' + COLORS.accent + '" stroke-width="1.6"/>' +
    '<circle cx="12" cy="12" r="3.2" fill="' + COLORS.accent + '"/></svg>';
  root.appendChild(bubble);

  // --- Chat panel ----------------------------------------------------------
  var panel = document.createElement("div");
  panel.className = "panel";
  panel.innerHTML =
    '<div class="hud">' +
    '  <span class="eye"></span>' +
    '  <span class="title">EYE~HELPI</span>' +
    '  <span class="status"><span class="dot"></span><span class="status-text">CONNECTING</span></span>' +
    "</div>" +
    '<div class="log"></div>' +
    '<div class="input-row"><input type="text" placeholder="Command Eye~Helpi..." aria-label="Command Eye~Helpi"><button aria-label="Send">&uarr;</button></div>' +
    '<div class="app-link"><a href="eyehelpi://chat">OPEN IN THE EYE~HELPI APP &rarr;</a></div>';
  root.appendChild(panel);

  document.body.appendChild(host);

  var log = panel.querySelector(".log");
  var input = panel.querySelector("input");
  var sendBtn = panel.querySelector(".input-row button");
  var statusEl = panel.querySelector(".status");
  var statusText = panel.querySelector(".status-text");
  var busy = null;

  function setStatus(text, online) {
    statusText.textContent = text;
    statusEl.classList.toggle("on", !!online);
  }

  function addMsg(role, text) {
    var el = document.createElement("div");
    el.className = "msg " + (role === "user" ? "you" : "eye");
    if (role === "assistant") {
      var tag = document.createElement("span");
      tag.className = "tag";
      tag.textContent = "EYE~HELPI";
      el.appendChild(tag);
    }
    el.appendChild(document.createTextNode(text));
    log.appendChild(el);
    log.scrollTop = log.scrollHeight;
    return el;
  }

  function setBusy(on) {
    if (on && !busy) {
      busy = document.createElement("div");
      busy.className = "busy";
      busy.textContent = "ANALYSING...";
      log.appendChild(busy);
      log.scrollTop = log.scrollHeight;
    } else if (!on && busy) {
      busy.remove();
      busy = null;
    }
    sendBtn.disabled = input.disabled = !!on;
  }

  bubble.addEventListener("click", function () {
    panel.classList.toggle("open");
    if (panel.classList.contains("open")) {
      if (!log.childElementCount) addMsg("assistant", GREETING);
      probeBrain();
      input.focus();
    }
  });

  // Reaches the agent once so the HUD status is honest.
  function probeBrain() {
    setStatus("CONNECTING", false);
    fetch(CONFIG.brainUrl.replace(/\/+$/, "") + "/api/status", { headers: authHeaders() })
      .then(function (r) {
        if (!r.ok) throw new Error("HTTP " + r.status);
        setStatus("ONLINE", true);
      })
      .catch(function (err) {
        setStatus((err.message || "").indexOf("401") !== -1 ? "TOKEN REJECTED" : "BRAIN OFFLINE", false);
      });
  }

  function send() {
    var text = input.value.trim();
    if (!text || busy) return;
    input.value = "";
    addMsg("user", text);
    setBusy(true);
    setStatus("THINKING", true);

    fetch(brainChatUrl(), {
      method: "POST",
      headers: Object.assign({ "Content-Type": "application/json" }, authHeaders()),
      body: JSON.stringify({
        messages: [
          { role: "system", content: PERSONA },
          { role: "user", content: text },
        ],
      }),
    })
      .then(function (r) {
        if (!r.ok) throw new Error("HTTP " + r.status);
        return r.json();
      })
      .then(function (data) {
        var reply =
          data.reply ||
          (data.message && data.message.content) ||
          "(no reply came back)";
        addMsg("assistant", reply);
        setStatus("ONLINE", true);
      })
      .catch(function (err) {
        var tokenRejected = (err.message || "").indexOf("401") !== -1;
        addMsg(
          "assistant",
          tokenRejected
            ? "The agent rejected the API token - check that apiKey in EYEHELPI_CONFIG matches the token stored on the agent (python main.py setkey)."
            : "I couldn't reach my brain at " + CONFIG.brainUrl + " (" + err.message + "). " +
              "The Eye~Helpi agent needs to be serving: python eye_helpi_agent/main.py serve --port 8765"
        );
        setStatus(tokenRejected ? "TOKEN REJECTED" : "BRAIN OFFLINE", false);
      })
      .finally(function () {
        setBusy(false);
        log.scrollTop = log.scrollHeight;
      });
  }

  sendBtn.addEventListener("click", send);
  input.addEventListener("keydown", function (e) {
    if (e.key === "Enter") send();
  });
})();