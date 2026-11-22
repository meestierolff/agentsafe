# AgentSafe

A Mac app that finds the API keys your AI agents left lying around, and keeps your keys behind Touch ID.

Coding agents read `.env` files and write what they see into plain-text transcripts on your disk. AgentSafe scans those places, ranks what it finds by how dangerous each key is, and gives you a safe to keep keys in instead. It runs in the macOS sandbox with no network permission, so nothing it reads can leave your Mac.

Website and download: https://safeagent.live

The source is published so you can check those claims yourself. It is source-available under the [Functional Source License](LICENSE.md): read it, build it and change it for your own use; each release becomes MIT-licensed two years after it is published. It is not an open-source licence in the OSI sense.

## What it does

- **Finds leaked keys.** Scans agent transcripts (Claude Code, Codex, Cursor), agent configs, shell history and `.env` files. Each finding says what the key can do, whether it is a live or sandbox key where the format shows it, and how serious it is. Findings are stored without the key: only the first and last few characters.
- **Checks git history.** Reads key files in git history (.env files, agent configs, chat logs, shell history and credential files in every commit) and says whether each commit was pushed, and to which remote. Pushed keys move up the rotation list. It reads `.git` directly, so it never runs `git` and never contacts the remote.
- **Turns findings into a rotation checklist,** worst first, with what to do next for each key and a count of how many are in `.env` files, in git history and only in git history.
- **Watches continuously.** The menu bar shield turns orange or red within seconds of a key landing in a transcript. An alert never opens the app by itself.
- **Keeps keys in a safe.** Opening the panel or the safe window asks for Touch ID, and reading a key back asks again, every time.
- **Tracks age and expiry,** and takes you straight to the page where each key is managed when it is time to rotate.
- **Starts projects without `.env` files.** `agentsafe run -- npm run dev` hands the keys to your command after you approve with Touch ID.
- **Hardens Claude Code** by adding deny rules for secret files.

## How the safe works

- Each key is encrypted to a public key stored in the safe file, so saving a key never requires the secret that opens the others.
- The matching private key is never stored in the clear. It is wrapped twice: under your master password (PBKDF2, 600,000 rounds) and under a Secure Enclave key that macOS uses only after Touch ID.
- The app is sandboxed without `com.apple.security.network.client`, so macOS blocks every connection it attempts. Check a build with `codesign -d --entitlements - /Applications/AgentSafe.app`.

## What it does not protect against

- **A leak cannot be undone.** A key that reached an agent transcript was already sent to the model provider. Removing the local copy helps; only rotating the key fixes it.
- **A key on screen can be captured** by an agent that takes screenshots. Copy is safer than Show.
- **An agent with full access to your Mac is slowed, not stopped.** It cannot pass Touch ID, but it can read anything you leave in plain files.
- **`agentsafe run` gives the key to the command you start.** That command can read it. Any program running as you can ask for keys, and the command line shown in the approval prompt is whatever the requester claims. That is why each key must be switched on for this before it can be requested, and why the prompt lists every key.
- **The Claude Code deny rules are a seatbelt.** They block its file tools and plain shell reads such as `cat`; they do not stop a script from opening the file.
- **Detection is by pattern.** It knows key formats and `.env` variable names, not your passwords. A clean scan is good news, not proof.
- **Git history is checked for key files, not source code.** A key typed into `config.ts` and committed is not found. "Pushed" means a remote-tracking branch has the commit, or had it before a force-push, as of your last fetch. Without network access the app cannot tell whether that repository is public.

## The command-line helper

The app bundle contains a small `agentsafe` program. It runs outside the sandbox, as any command-line tool must to start your commands. It has no network code and never stores a key.

```bash
agentsafe init                     # write agentsafe.keys from the names in .env (names only)
agentsafe run -- npm run dev       # start a command with those keys, after Touch ID
agentsafe run --keys A,B -- cmd    # or name the variables directly
```

The helper and the app meet in `~/.agentsafe/`: the helper writes a request, the app asks you, and the reply is encrypted to a key that exists only in the helper's memory for that one request.

## For AI agents

[`skills/agentsafe/SKILL.md`](skills/agentsafe/SKILL.md) is a skill file you can give to a coding agent. It tells the agent never to read secret files, how to move a project onto `agentsafe run`, and how to propose limits on its own access.

## Build it yourself

Requires macOS 14 or later and Xcode.

```bash
cd app
swift test                    # the test suite
./scripts/build-app.sh        # builds dist/AgentSafe.app, universal, sandboxed and signed
open dist/AgentSafe.app
```

Without a signing certificate the script signs ad hoc, which runs on your own Mac.

Other flags on the built app binary: `--selftest` prints whether the sandbox and the network block are in effect, and `--snapshot <folder>` renders every screen to PNG with made-up data.

## Repository layout

| Folder | What it is |
|---|---|
| `app/` | The Mac app, a Swift package. `AgentSafeCore` holds the logic and its tests, `AgentSafe` is the interface, `AgentSafeCLI` is the `agentsafe` command. |
| `web/` | The website: landing page, checkout and licence page. |
| `shared/` | The licence public key, and a test licence that the website and the app must agree on. |
| `skills/` | The skill file for AI agents. |

## Licences for the app

Scanning, the list of leaked keys, rotation links and three keys in the safe are free. A licence adds exact file locations, one-click removal, unlimited keys and the continuous watch. Licence keys are checked offline with a public key built into the app; the app never contacts a server.

## Status

This is a new project by one person. The logic is covered by tests, including an end-to-end test of the command-line helper. It has had limited use on real machines so far. If you find a key format it misses, or a false positive, an issue describing the format (never a real key) is welcome.

AgentSafe is independent and is not affiliated with Apple or with any provider it scans for.
