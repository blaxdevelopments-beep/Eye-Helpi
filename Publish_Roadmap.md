# Eye~Helpi - Full Audit & Publish Roadmap

Audit date: after the full app review (chat, device hub, agent, widget).

## Part 1 - What was verified working today

| Area | Check | Result |
|---|---|---|
| iOS app | Full simulator build, all 20 Swift files | PASS |
| Python agent | `py_compile` on every module | PASS |
| Website widget | `node --check` on the widget JS | PASS |
| Tool registry ↔ agent loop | schema shapes, `run_tool` contract | Consistent |
| Watchdog ↔ device controls | disposal "candidates" data shape | Consistent |
| Widget ↔ agent API | `/api/chat`, `/api/status`, Bearer token flow | Consistent |
| Persona | identical across `config.py`, iOS `AgentConfig`, widget | Consistent |
| Permissions | camera, mic, speech, HomeKit, NFC (NDEF), Bluetooth, Local Network | All present in Info.plist |
| Entitlements | HomeKit + NFC present | Present |
| App icon | 1024px icon in asset catalog | Present |
| Keys | OpenAI fallback key registered and entered; agent token via `setkey` | Configured |

What the app contains: streaming chat with the llama3.2-vision brain, OpenAI
cloud fallback when Ollama is unreachable, live camera analysis, 8-second
"live watch" mode with change detection, on-device Vision pre-scans (faces +
text), document scanning, spoken en-AU replies, voice commands, predictive
rhythm learning, battery-protective autopilot, HomeKit read-only status, NFC
tag reading, Bluetooth file beaming (gated by the permission engine),
deep links (`eyehelpi://chat?text=...`), TLS pinning support, and the
token-authenticated website widget.

## Part 2 - What cannot be verified from this device

1. **Runtime behaviour on real hardware** - camera, microphone, NFC, HomeKit,
   Bluetooth and document scanning all need a real iPhone build; the
   simulator has none of that hardware.
2. **The agent's first real run** - it has compiled but never executed: no
   chat round-trip against Ollama has happened yet, and ffmpeg/imageSnap
   (recording, webcam frames) are optional binaries that may not be installed.
3. **Your live website** - I can't upload `eyehelpi-widget.js` to
   blaxdevelopments.com; that file transfer is yours.

## Part 3 - Publish roadmap (do these in order)

### A. Agent first (everything depends on it)

1. First real run: `python eye_helpi_agent/main.py chat` - verify the brain
   answers and tool calls work (battery, screenshot).
2. Grant macOS permissions to your terminal: Screen Recording, Camera,
   Microphone (System Settings > Privacy & Security).
3. Install optional binaries if you want recording/webcam tools:
   `brew install ffmpeg imagesnap`.
4. Store your website token: `python main.py setkey <your blaxdevelopments.com
   API token>` - this is also the web access token.
5. If you want LAN access from phone/web: `launchctl setenv OLLAMA_HOST
   0.0.0.0` and restart Ollama.
6. Decide on autopilot consents (`grant_consent`) - they are off by default.

### B. Website widget

7. Upload `website-integration/eyehelpi-widget.js` to
   blaxdevelopments.com and paste the embed snippet (with your LAN IP and the
   same `apiKey`) before `</body>`.
8. HTTPS check: if the site is served over HTTPS, a plain-HTTP brain URL will
   be blocked by the browser (mixed content). Either test while on the same
   network over HTTP, or put the agent behind a reverse proxy with TLS
   (`eyehelpi.blaxdevelopments.com` + Let's Encrypt) and point `brainUrl`
   there.
9. Add the `.com.au` DNS record pointing at the same server, and both
   hostnames in the web server's `server_name`.
10. Test the widget from a second device on your network.

### C. iOS app on a real iPhone

11. Change the bundle identifier from the template value
    `com.organizationName.Eye-Helpi` to `com.blaxdevelopments.eyehelpi`
    (do this before creating any App Store record or signing identity).
12. Device build + on-device pass: camera analysis, live watch, voice
    commands, spoken replies, NFC read, document scan, HomeKit homes.
13. Set the agent host in the Setup tab to your Mac's LAN IP; verify chat
    works away from the OpenAI fallback.
14. Optional hardening: add `TLS_PINS.plist` with OpenAI certificate pins
    (see TLS_PINS.plist.example).

### D. App Store publication (only if you want the app distributed that way)

15. Privacy policy URL on blaxdevelopments.com (Apple requires one) - state
    that camera frames go to your own Ollama host and that the OpenAI
    fallback sends text (and images, when the brain is cloud) to OpenAI.
16. App Privacy "nutrition label" answers, screenshots, review notes
    explaining that the app needs a user-run Ollama agent on the network.
17. Set final version/build numbers, then submit for review.

### E. Housekeeping (before or right after publishing)

18. Commit everything - the working tree holds work from multiple sessions
    that is not yet in git history.
19. Decide repository visibility; if public, strip personal email addresses
    from any docs first.
20. Add a GitHub Actions workflow: Python `py_compile` + JS `node --check` +
    iOS build on every push.
21. Later: rotate the web token periodically; consider per-visitor tokens if
    the widget becomes popular.

## Bottom line

Nothing is broken - everything that can be compiled compiles and every
cross-module contract checks out. The distance to publish is one of *runtime
proof* (first agent run, first device build, first widget on the live site)
plus the App Store paperwork. Items A1-B10 are a single sitting each; C-D
need a Mac with Xcode for the device build