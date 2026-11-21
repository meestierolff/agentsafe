---
name: agentsafe
description: Use when a task touches API keys, tokens, passwords or .env files on a Mac where the AgentSafe app is (or should be) installed - setting a project up so its secrets come from AgentSafe instead of a .env file, starting a command that needs secrets, or proposing how to restrict your own access to secret files.
---

# AgentSafe

AgentSafe is a Mac app that keeps API keys encrypted behind Touch ID. Its `agentsafe` command starts a program with the keys it needs as environment variables, after the person approves on their Mac. You never need to see a key to get work done, and you should arrange things so that you don't.

Anything you read is written to your transcript and sent to your model provider. A key you have read is a key that has to be replaced. That is the reason for every rule below.

## Rules that always apply

- Do not open, print, search or copy `.env` files, or any other file that holds secrets (`~/.aws/credentials`, `~/.ssh/*`, `*.pem`, `~/.npmrc`). This includes `cat`, `grep`, `head`, an editor, and any script you write.
- Watch for commands that sweep them up by accident: `grep -r`, `rg`, `cat *`, or a search tool run over the whole project folder. Exclude `.env*` or search a subfolder.
- Seeing that such a file exists is fine. Listing a folder, or checking a file's name, size or git status, reads nothing secret.
- Do not print environment variables that hold secrets. No `env`, `printenv`, `echo $SOME_KEY`, and no debug logging of them.
- Do not ask the person to paste a key into the chat. If they offer, ask them to put it in AgentSafe instead.
- Do not write a key into source code, a config file, a commit, a log or a test.
- If a key appears in something you read or in a command's output, stop and say so plainly: name where it appeared and tell the person it should be rotated. Do not repeat the key.

## Check that the command is available

```bash
command -v agentsafe && agentsafe version
```

If it is missing, do not try to install it yourself. Tell the person: open AgentSafe, go to Settings, "Command line", and run the link command shown there in their own terminal. Your shell's PATH may differ from theirs, so if it works for you, still mention where it came from.

## Set a project up

Do your own steps first, then hand the person their steps as one list. Do not stop and wait in the middle.

**Your steps**

1. In the project folder, run:

   ```bash
   agentsafe init
   ```

   The tool (not you) reads `.env` and writes the names of the secret variables to `agentsafe.keys`. It prints names only and leaves out ordinary settings such as `PORT`. If the secrets are in a different file, name it: `agentsafe init --from .env.local`. It refuses to overwrite an existing `agentsafe.keys`; if one exists, read that file instead (it never contains values).

2. Change how people are told to start the project. Put the usual command after `--`:

   ```bash
   agentsafe run -- npm run dev
   ```

   Update the README. Do not put `agentsafe run` inside the `dev` script itself: it would call itself, and it would break the project on machines without AgentSafe, such as CI. If a shortcut is wanted, add a separate script (for example `"dev:safe": "agentsafe run -- npm run dev"`).

3. Make sure `.env` is in `.gitignore`; add it if it is missing. If git already tracks `.env`, tell the person: the keys in it are in the repository's history and should be rotated.

4. `agentsafe.keys` holds names only and is meant to be committed.

**The person's steps** (list these for them)

1. For each name in `agentsafe.keys`, store the key in AgentSafe under that variable name, and switch on "Commands may use this key" on the key's page. Keys are off for this by default.
2. Start the project with `agentsafe run -- <command>` and approve the prompt.
3. Check the keys really arrive, without printing them. This prints only whether a variable is set:

   ```bash
   agentsafe run -- sh -c 'test -n "$OPENAI_API_KEY" && echo "OPENAI_API_KEY is set"'
   ```

4. Then remove the secret values from `.env`. Ordinary settings (ports, public URLs) can stay there. Do not do this step yourself: you would have to open the file.

Until the values are removed from `.env`, avoid starting the project the old way yourself if it logs its configuration: a key in the log is a key in your transcript.

A line in `agentsafe.keys` is either a variable name, or `NAME = name of the key in the safe` when the key is stored under a different name.

## Run a command that needs secrets

```bash
agentsafe run -- <command> [arguments]
agentsafe run --keys OPENAI_API_KEY,STRIPE_SECRET_KEY -- <command>
```

The first form uses `agentsafe.keys` from this folder or a parent. The second names the variables directly.

The person sees a prompt on their Mac listing the command and every key, and approves with Touch ID. Tell them a prompt is coming before you run it. Each run asks again.

Only run the project's real commands this way (its dev server, tests, a deploy script). Never use it to look at a key: `agentsafe run -- env` and anything like it is exactly what the person is trusting you not to do.

| Exit code | Meaning | What to do |
|---|---|---|
| the command's own | The command ran | Carry on as usual |
| 2 | Wrong usage, or no keys named | Fix the command; check `agentsafe.keys` exists |
| 3 | No approval in time, or the app is not running | Tell the person; do not retry in a loop |
| 4 | Refused, or a key is missing or not switched on | Relay the message it printed. It lists the names you asked for, not which of them was the problem |
| 127 | The command could not be started | Check the command name and PATH |

AgentSafe's own messages go to standard error and start with `agentsafe:`. If the command you ran also uses exit code 2, 3 or 4, that prefix tells you which of the two spoke.

After a 3 or a 4, ask before trying again. Repeated prompts train people to approve without reading.

## Propose limits on your own access

Raise this once when you set a project up, or when asked. You should not edit your own permission settings: propose the change and let the person apply it.

- **Claude Code:** AgentSafe has a "Harden agents" tab that adds deny rules to `~/.claude/settings.json` with one click. Point the person there. The rules look like this, and apply in every project:

  ```json
  { "permissions": { "deny": ["Read(//**/.env)", "Read(//**/.env.local)", "Read(~/.ssh/**)", "Read(~/.aws/credentials)"] } }
  ```

  Be honest about what they do: they stop the file tools and plain shell reads such as `cat`. They do not stop a script from opening the file. They are a seatbelt, and the rules above still apply.

- **Other agents (Codex, Cursor and so on):** each has its own way to restrict file access. Do not guess the syntax. Tell the person which files should be off limits (the list under "Rules that always apply") and ask them to check that tool's documentation.

## What AgentSafe does not do

Say these plainly if asked, and do not promise more.

- A command that receives a key can read it. AgentSafe keeps keys out of files and out of your context; it does not hide them from the program that uses them.
- It does not replace keys at the provider. Rotation still happens on the provider's website; AgentSafe stores the new value and every project picks it up on its next run.
- It only supplies keys to commands on this Mac. Hosted environments (Vercel, CI) keep their own copies and must be updated separately.
