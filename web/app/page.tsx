import { NotchDemo } from "./notch-demo";
import { LADDER, formatUSD, ladderState } from "../lib/pricing.mjs";
import { countPaidSales, salesAreOpen } from "../lib/stripe.mjs";

// Re-check the sale count at most once a minute, so the price on the page stays current.
export const revalidate = 60;

const tiers = Array.from(
  { length: (LADDER.capCents - LADDER.startCents) / LADDER.stepCents + 1 },
  (_, i) => LADDER.startCents + i * LADDER.stepCents,
);

function Window({ id, title, children }: { id: string; title: string; children: React.ReactNode }) {
  return (
    <section className="window" id={id} aria-labelledby={`${id}-title`}>
      <div className="titlebar">
        <span className="lights" aria-hidden="true">
          <i style={{ ["--c" as string]: "#ee5b54" }} />
          <i style={{ ["--c" as string]: "#f5bd3d" }} />
          <i style={{ ["--c" as string]: "#5fc44d" }} />
        </span>
        <span id={`${id}-title`}>{title}</span>
      </div>
      <div className="pane">{children}</div>
    </section>
  );
}

export default async function Home() {
  const open = salesAreOpen();
  const sold = open ? await countPaidSales({ revalidate: 60 }).catch(() => 0) : 0;
  const ladder = ladderState(sold);
  const price = formatUSD(ladder.priceCents);
  const downloadURL = process.env.DOWNLOAD_URL;

  return (
    <div className="desktop">
      <header className="menubar">
        <a className="brand" href="#top">
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img src="/icon.png" alt="" width={18} height={18} />
          AgentSafe
        </a>
        <nav aria-label="Sections">
          <a href="#leaks">Leaks</a>
          <a href="#safe">Safe</a>
          <a href="#trust">Trust</a>
          <a href="#price">Price</a>
        </nav>
        <span className="status">Runs offline on your Mac</span>
      </header>

      <NotchDemo />

      <main className="column" id="top">
        <div className="hero">
          <h1>A smoke detector and a safe for your API keys.</h1>
          <p>
            AgentSafe sits at the top of your screen, beside your menu bar icons or over the notch. It tells you the
            moment an AI agent leaves an API key in a transcript, a config file or your shell history, and it keeps
            your keys behind Touch ID, where agents cannot read them.
          </p>
          <div className="actions">
            {downloadURL ? (
              <a className="gel" href={downloadURL}>Download for Mac</a>
            ) : (
              <span className="gel" aria-disabled="true">Download opens soon</span>
            )}
            <a className="gel plain" href="#price">Licence from {price}</a>
          </div>
          <p className="small">The scan is free. Pay once, keep your Mac safe forever. macOS 14 or later. No account, no cloud.</p>
        </div>

        <Window id="leaks" title="What your agents left behind">
          <div className="split">
            <div>
              <h2>Agent transcripts are the new .env file.</h2>
              <p>
                Every time an agent reads a key, or you paste one into a chat, it is written to a plain text file on
                your disk and kept for weeks. Anything running as you can read those files, and their contents were
                already sent to the model provider.
              </p>
            </div>
            <div>
              <h3>Where AgentSafe looks</h3>
              <ul>
                <li>Claude Code, Codex and Cursor history</li>
                <li>The usual folders for Windsurf, Gemini CLI, OpenCode and Aider (less tested so far)</li>
                <li>Agent settings and MCP configs, including &ldquo;don&rsquo;t ask again&rdquo; approvals</li>
                <li>Shell history</li>
                <li>.env files across your projects</li>
              </ul>
              <h3>What you get</h3>
              <p>
                Every leaked key, worst first. Each one says in plain words what it can do, whether it is a live or
                a sandbox key, how many files it is in, and gives a link to the provider&rsquo;s page to replace it.
                Results are stored without the key itself: only the first and last few characters.
              </p>
              <p>
                With a licence you also see the exact file and line of every copy, and one click removes them all
                from your transcripts and shell history. The watch then runs all the time, and the icon turns red
                within seconds of a key landing in a transcript.
              </p>
            </div>
          </div>
          <div>
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img className="shot" src="/screens/safe-leaks.png" width={1600} height={1157} loading="lazy"
                 alt="The Leaks tab listing four leaked keys, worst first. A Stripe live key is marked critical, with a description of what it can do and buttons to open Stripe, mark it rotated and remove the local copy." />
          </div>
        </Window>

        <Window id="safe" title="The safe">
          <div className="split">
            <div>
              <h2>Putting a key in takes a second. Getting one out takes your fingerprint.</h2>
              <p>
                Copy a new key at the provider, paste it into the panel, done. AgentSafe recognises more than 25 key
                formats and names the key for you.
              </p>
              <p>
                Saving needs no unlock, because each key is encrypted the moment it arrives. Reading one back needs
                Touch ID or your master password, every time. An agent can type and click. It cannot touch a sensor.
              </p>
            </div>
            <div>
              <ul>
                <li>Copied keys leave the clipboard after 30 seconds and are marked so clipboard managers skip them</li>
                <li>Each key shows its age, with a reminder when it is time to replace it</li>
                <li>Expiry dates, for keys that have one</li>
                <li>One encrypted backup file, since there is no cloud</li>
                <li>One click adds rules that stop Claude Code reading your .env files</li>
                <li>
                  Start a project straight from the safe: <code>agentsafe run -- npm run dev</code> hands the keys to
                  your command after Touch ID, so the project needs no .env file with real values
                </li>
              </ul>
            </div>
          </div>
          <div>
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img className="shot" src="/screens/safe-keys.png" width={1600} height={1157} loading="lazy"
                 alt="The Keys tab with six stored keys. The selected Anthropic key is marked as leaked, with Copy, Show for 12 seconds and Rotate this key buttons." />
          </div>
        </Window>

        <Window id="trust" title="Why you can trust it">
          <h2>It cannot phone home. macOS will not let it.</h2>
          <p>
            A tool that reads all your keys has to answer one question: where do they go? AgentSafe runs in the macOS
            sandbox with no network permission. That is enforced by the system, not by a promise, and you can check
            it yourself:
          </p>
          <pre>codesign -d --entitlements - /Applications/AgentSafe.app</pre>
          <p>
            You will see permission to read folders you choose, and nothing about the network. The price of that is
            honest too: the app cannot check for updates, so new versions are announced here.
          </p>
          <p>
            One part runs outside the sandbox: the optional <code>agentsafe</code> command-line helper, because a
            sandboxed program could not start your commands. It has no network code and never stores a key. The
            whole source, helper included, is{" "}
            <a href="https://github.com/meestierolff/agentsafe">public on GitHub</a> so you can read it or build
            the app yourself.
          </p>
          <div className="pair">
            <div className="box">
              <h3>What it does</h3>
              <ul>
                <li>Keeps keys encrypted on disk, never in a plain file</li>
                <li>Asks for Touch ID before any key is copied or shown</li>
                <li>Finds keys that already leaked, and watches for new ones</li>
                <li>Stores findings without the secret in them</li>
              </ul>
            </div>
            <div className="box">
              <h3>What it cannot do</h3>
              <ul>
                <li>Undo a leak. A key that reached a transcript was sent to the provider. Only replacing it fixes that.</li>
                <li>Hide a key you choose to show on screen from an agent that can take screenshots. Copy instead.</li>
                <li>Stop a determined agent that has full access to your Mac. It removes the easy paths.</li>
                <li>Hide a key from the command you hand it to. <code>agentsafe run</code> keeps keys out of files and out of an agent&rsquo;s context; the program that uses a key can still read it.</li>
                <li>Catch every secret. It knows key formats and .env names, not your passwords.</li>
              </ul>
            </div>
          </div>
        </Window>

        <Window id="price" title="Price">
          <h2>Pay once, keep your Mac safe forever.</h2>
          <p>
            The price goes up as people buy. It starts at {formatUSD(LADDER.startCents)} and rises by $1 after every{" "}
            {LADDER.salesPerStep} sales until it reaches {formatUSD(LADDER.capCents)}, where it stays. VAT is
            included where it applies.
          </p>
          <div className="lcd price-lcd" aria-label={`Current price ${price}`}>
            <span className="seg"><b>{price}</b><span>ONCE</span></span>
            {open && <span className="seg"><b>{ladder.sold >= 100 ? "100+" : ladder.sold}</b><span>SOLD</span></span>}
            <span className="tail">
              {!open
                ? "SALES OPEN SOON"
                : ladder.nextPriceCents
                  ? `${ladder.leftAtThisPrice} LEFT AT THIS PRICE, THEN ${formatUSD(ladder.nextPriceCents)}`
                  : "FINAL PRICE"}
            </span>
          </div>
          <ol className="ladder" aria-label="Price steps">
            {tiers.map((cents) => (
              <li key={cents} className={cents < ladder.priceCents ? "past" : cents === ladder.priceCents ? "now" : ""}>
                {formatUSD(cents)}
              </li>
            ))}
          </ol>
          <div className="pair">
            <div className="box">
              <h3>Free</h3>
              <ul>
                <li>Scan whenever you like</li>
                <li>See every leaked key, how serious it is, and where to replace it</li>
                <li>One click to stop Claude Code reading .env files</li>
                <li>Three keys in the safe</li>
                <li>Encrypted backup</li>
              </ul>
            </div>
            <div className="box">
              <h3>Licence</h3>
              <ul>
                <li>The exact file and line of every leaked copy</li>
                <li>Remove all local copies in one click</li>
                <li>As many keys as you have</li>
                <li>The always-on watch, with alerts</li>
                <li>Rotation and expiry reminders</li>
                <li>Every later version</li>
              </ul>
              {open ? (
                <form action="/api/checkout" method="post">
                  <button className="gel" type="submit">Buy a licence for {price}</button>
                </form>
              ) : (
                <span className="gel" aria-disabled="true">Sales open soon</span>
              )}
            </div>
          </div>
        </Window>

        <Window id="questions" title="Questions">
          <h2>Before you download</h2>
          <details>
            <summary>My Mac has no notch. Does it work?</summary>
            <p>Yes. AgentSafe sits beside your menu bar icons by default, which works on every Mac. On a MacBook with a notch you can move it there in Settings.</p>
          </details>
          <details>
            <summary>Where are my keys stored?</summary>
            <p>In one encrypted file inside the app&rsquo;s private folder on your Mac. The key that opens it is itself locked twice: once by your Mac&rsquo;s Secure Enclave, which answers only after Touch ID, and once by your master password.</p>
          </details>
          <details>
            <summary>What if I forget my master password?</summary>
            <p>While Touch ID works, you can still use your keys. Without both, nobody can open the safe, including us. Keep a backup and write the password down somewhere offline.</p>
          </details>
          <details>
            <summary>Why does it ask to read my home folder?</summary>
            <p>Agent transcripts, shell history and .env files live there. macOS shows a folder dialog and the app can read only what you choose. It cannot send what it reads anywhere.</p>
          </details>
          <details>
            <summary>I already use a password manager. Why this?</summary>
            <p>Keep it for passwords. AgentSafe does two things most managers do not: it looks for keys that already escaped into agent files, and it never shows a pop-up for an agent to click.</p>
          </details>
          <details>
            <summary>Can my AI agent set this up for me?</summary>
            <p>
              Yes. Give it the{" "}
              <a href="https://github.com/meestierolff/agentsafe/blob/main/skills/agentsafe/SKILL.md">AgentSafe skill file</a>.
              It tells the agent never to open your secret files, how to move a project onto <code>agentsafe run</code>,
              and to propose limits on its own access for you to apply.
            </p>
          </details>
          <details>
            <summary>How do I get updates?</summary>
            <p>The app has no network access, so it cannot fetch them. Download the new version here and drag it over the old one. Your safe stays where it is.</p>
          </details>
        </Window>

        <footer className="site">
          <p>AgentSafe runs on macOS 14 or later, on Apple silicon and Intel. It is an independent app and is not affiliated with Apple or with any AI provider it scans for.</p>
        </footer>
      </main>
    </div>
  );
}
