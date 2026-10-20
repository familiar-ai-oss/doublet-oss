# Doublet

A native Mac, iPad and iPhone app for working with Claude Code. Claude runs on a machine you own, and every device
shows the same live session: what Claude is doing, its plan, the files it touches, and anything waiting for your
approval.

## Features

- **One session on every device.** Start on the Mac, approve from the iPhone's Lock Screen, review the diff on the
  iPad. Handoff picks up where you left off.
- **Apple Pencil.** Write on code or diagrams. Questions come back as short answers next to the lines you circled.
- **Diagrams linked to code.** Claude draws Mermaid diagrams whose parts open the lines they explain.
- **Files and terminals** on the hub, with git status.
- **Sessions started elsewhere.** Follow Claude Code sessions you started on the hub in a terminal or another app.
- **Local models (optional).** Claude can hand mechanical work to a model on Ollama instead of using your Claude usage.

## How it works

```
Mac / iPad / iPhone  ──  Tailscale  ──▶  hub (Node.js)  ──▶  your Claude Code
```

The hub is a small Node.js service on a machine you own. It drives your installed Claude Code through the
[Agent SDK](https://code.claude.com/docs/en/agent-sdk/overview) and streams the session to the apps over your
Tailscale network.

Doublet has no sign-in of its own. Claude Code uses whatever you signed it in with: an API key, your Claude plan, or
a cloud provider. Usage is billed to you exactly as if you were running Claude Code yourself.

## Requirements

**Hub:** an always-on Linux machine with systemd, Node.js 22.18+, [Claude Code](https://code.claude.com) installed
and signed in, and [Tailscale](https://tailscale.com) with HTTPS enabled. Optionally [Ollama](https://ollama.com).

**Apps:** a Mac with Xcode (macOS 27 and iOS 27 SDKs), [XcodeGen](https://github.com/yonaskolb/XcodeGen), an Apple
developer team (a free Personal Team works), and Tailscale on each device.

## Quick start

**1. Configure.** Copy the three example files:

```bash
cp hub/local.env.example hub/local.env && cp app/Config/Local.xcconfig.example app/Config/Local.xcconfig && cp local.mk.example local.mk
```

Then fill in:
- `local.mk`: `HOST`, the ssh alias of your hub machine.
- `hub/local.env`: `DUET_ALLOWED_LOGINS`, your Tailscale login (for example `you@github`).
- `app/Config/Local.xcconfig`: `DUET_BUNDLE_ID` and `DUET_TEAM`.

These files are git-ignored.

**2. Install the hub.** From the Mac:

```bash
make install-hub
```

This copies the hub to `HOST`, installs it as a systemd user service, and serves it at
`https://<hub>.<tailnet>.ts.net:8443`. To keep it running after you log out, run `sudo loginctl enable-linger $USER`
once on the hub.

**3. Create a token for each device.** On the hub:

```bash
cd ~/duet-hub && node --experimental-strip-types src/main.ts token add ipad
```

**4. Build the apps.**

```bash
cd app && xcodegen && open Duet.xcodeproj
```

Run the `Duet-macOS` or `Duet-iOS` scheme. In Settings, enter `wss://<hub>.<tailnet>.ts.net:8443/ws`, the device
name and its token.

To update the hub later, run `make deploy-hub && make restart-hub`.

## Configuration

The hub reads `hub/local.env`. Anything set in the environment wins.

| Setting | What it does |
|---|---|
| `DUET_ALLOWED_LOGINS` | Tailscale logins allowed in, comma-separated. Empty: local connections only. |
| `DUET_PROJECT_DIR` | The folder Claude starts in. Default: your home folder. |
| `DUET_LEAD_MODEL`, `DUET_LEAD_EFFORT` | Claude's model and effort. Default: `claude-opus-5-5`, `high`. |
| `DUET_OLLAMA_URL`, `DUET_OLLAMA_MODEL` | Ollama for local workers. Default: `http://127.0.0.1:11434`, `qwen3:8b`. |
| `ANTHROPIC_API_KEY` | Use an API key instead of Claude Code's own sign-in. |
| `DUET_LEAD_AUTH` | `subscription` or `max`: run only on your Claude plan, never on an API key. |
| `DUET_CLAUDE_PATH` | The `claude` to run, if it isn't on `PATH` or in `~/.local/bin`. |

For several local workers, copy `hub/fleet.example.json` to `hub/fleet.local.json`. Each worker's server must speak
Anthropic's Messages API, as Ollama does.

## Development

- Hub: `cd hub && npm test`. Some tests need a signed-in Claude Code or local models.
- Apps: `cd app/DuetKit && swift test`, plus the unit and UI tests in the Xcode schemes.

## License

[Apache License 2.0](LICENSE). Bundles Mermaid (MIT) and highlight.js (BSD 3-Clause); see [NOTICE](NOTICE).

Doublet is an independent project and isn't affiliated with Anthropic.
