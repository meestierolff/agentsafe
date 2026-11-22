import { AppIcon, Caution, DownloadButton, SectionHead, SeverityPill, TitleBar } from "./components/chrome";
import { Faq, InfoWindow, SafeDemo, WatchDemo } from "./components/demos";
import { Dock, MacBook } from "./components/hero-scene";
import { SiteMenuBar } from "./components/site-menu-bar";
import { LADDER, formatUSD, ladderState } from "../lib/pricing.mjs";
import { countPaidSales, salesAreOpen } from "../lib/stripe.mjs";

// Re-check the sale count at most once a minute, so the price on the page stays current.
export const revalidate = 60;

const REPO = "https://github.com/meestierolff/agentsafe";
const SKILL = `${REPO}/blob/main/skills/agentsafe/SKILL.md`;

const tiers = Array.from(
  { length: (LADDER.capCents - LADDER.startCents) / LADDER.stepCents + 1 },
  (_, i) => LADDER.startCents + i * LADDER.stepCents,
);

// Key formats the app's detector recognises (AgentSafeCore/SecretDetector.swift).
const formats: [string, string][] = [
  ["sk-ant-", "Anthropic"], ["sk-proj-", "OpenAI"], ["sk_live_", "Stripe live"], ["sk_test_", "Stripe sandbox"],
  ["ghp_", "GitHub"], ["github_pat_", "GitHub fine-grained"], ["AKIA", "AWS"], ["xoxb-", "Slack"], ["AIza", "Google"],
  ["glpat-", "GitLab"], ["hf_", "Hugging Face"], ["sk-or-v1-", "OpenRouter"], ["xai-", "xAI"], ["gsk_", "Groq"],
  ["re_", "Resend"], ["sbp_", "Supabase"], ["napi_", "Neon"], ["postgres://", "Database passwords"],
  ["*_SECRET", ".env names"], ["*_TOKEN", ".env names"],
];

const limits: [string, string][] = [
  ["A leak cannot be undone.", "A key that reached an agent transcript was already sent to the model provider. Removing the local copy helps; only rotating the key fixes it."],
  ["A key on screen can be captured.", "An agent that takes screenshots can see it. Copy is safer than Show."],
  ["Full access is slowed, not stopped.", "An agent with full access to your Mac cannot pass Touch ID, but it can read anything you leave in plain files."],
  ["agentsafe run trusts the command you start.", "That command can read the key. Any program running as you can ask for keys, and the command line in the prompt is whatever the requester claims. That is why each key must be switched on first, and why the prompt lists every key."],
  ["Deny rules are a seatbelt.", "They block Claude Code's file tools and plain shell reads such as cat. They do not stop a script from opening the file."],
  ["Detection is by pattern.", "It knows key formats and .env variable names, not your passwords."],
  ["Git history means key files, not code.", "It reads .env files, agent configs, chat logs and shell history in every commit, not source code. Pushed means a remote branch has the commit as of your last fetch; without network access it cannot tell whether that repository is public."],
];

const faqs = [
  { q: "Can AgentSafe send my keys anywhere?", a: "No. The app runs in the macOS sandbox without the network client entitlement, so macOS blocks every connection it attempts. Check any build with codesign, or run the app binary with --selftest." },
  { q: "Does it keep a copy of the keys it finds?", a: "No. Findings are stored without the key: only the first and last few characters, enough for you to recognise it." },
  { q: "I found a leaked key. Is deleting the transcript enough?", a: "No. A key that reached a transcript was already sent to the model provider. Removing the local copy helps; only rotating the key fixes it. AgentSafe takes you to the page where that key is managed." },
  { q: "Does it check git history?", a: "Yes, for key files: every past version of .env files, agent configs, chat logs, shell history and credential files, in every repository in your home folder. It says whether each commit was pushed and to which remote, and lists pushed keys higher. Keys that only other people committed, such as sample keys in projects you cloned, are counted but not listed. Rotating is the fix; rewriting history is optional clean-up, and AgentSafe never does it for you." },
  { q: "Will removing leaked copies break my apps?", a: "No. Removal only rewrites records nothing reads a key back from: agent transcripts and shell history. .env files, agent configs and credential files are left alone and listed as in use. To get a key out of a .env file, move the project onto agentsafe run, then rotate the key." },
  { q: "Can an agent open the safe?", a: "It cannot pass Touch ID, and every read asks again. It can still read anything you leave in plain files, and a command you start with agentsafe run can read the keys it is given." },
  { q: "Will an alert interrupt me?", a: "The shield in the menu bar changes colour and a notification appears. An alert never opens the app by itself." },
  { q: "Why does the command-line helper run outside the sandbox?", a: "Any command-line tool must, to start your commands. The helper has no network code and never stores a key." },
  { q: "What if I forget my master password?", a: "While Touch ID works you can still use your keys. Without both, nobody can open the safe, including us. Keep an encrypted backup, and write the password down somewhere offline." },
  { q: "How do I get updates?", a: "The app has no network access, so it cannot check for them. Download the new version here and drag it over the old one. Your safe stays where it is." },
  { q: "What do I need?", a: "macOS 14 Sonoma or later. Building from source also needs Xcode." },
];

export default async function Home() {
  const open = salesAreOpen();
  const sold = open ? await countPaidSales({ revalidate: 60 }).catch(() => 0) : 0;
  const ladder = ladderState(sold);
  const price = formatUSD(ladder.priceCents);
  const downloadUrl = process.env.DOWNLOAD_URL || undefined;

  return (
    <div className="page">
      <div className="pinstripes" aria-hidden="true" />
      <div className="page-content">
        <SiteMenuBar downloadUrl={downloadUrl} />

        {/* ── Hero ── */}
        <div className="hero-wrap">
          <div className="hero-backdrop" aria-hidden="true">
            <div className="aurora" />
            <div className="stars" />
          </div>
          <section id="top" className="hero">
            <div className="badge"><span className="led glow" />Runs with no network permission. Nothing it reads can leave your Mac.</div>
            <h1>
              <span>Keys belong in a safe,</span>
              <span className="tint">not in a transcript.</span>
            </h1>
            <p className="hero-sub">
              Coding agents read .env files and write what they see into plain-text transcripts on your disk. AgentSafe
              finds those keys, ranks them by how dangerous each one is, and gives you a safe to keep them in instead.
            </p>
            <div className="hero-ctas">
              <DownloadButton url={downloadUrl} />
              <a className="btn btn-lg btn-grey" href="#how">How the safe works</a>
            </div>
            <div className="hero-note">macOS 14 Sonoma or later · Universal · Sandboxed and notarized</div>
            <Dock />
          </section>
          <MacBook />
        </div>

        <div className="trust">
          <span><span className="blue-dot" />No network permission</span>
          <span><span className="blue-dot" />Touch ID for every read</span>
          <span><span className="blue-dot" />Findings stored masked, never whole</span>
          <span><span className="blue-dot" />Sandboxed and notarized</span>
        </div>

        {/* ── Finds leaked keys ── */}
        <section id="finds" className="section">
          <SectionHead
            eyebrow="Finds leaked keys"
            title="Every leaked key, ranked by the damage it can do"
            sub="Each finding says what the key can do, whether it is a live or sandbox key where the format shows it, and how serious it is. AgentSafe keeps only the first and last few characters. Never the key."
            pills={["Live or sandbox, read from the format", "Stored masked"]}
          />
          <div className="frame aqua-frame">
            <div className="hud">
              <div className="hud-title"><div className="hud-close" aria-hidden="true">×</div>Finding</div>
              <div className="hud-cols">
                <div className="hud-left">
                  <div style={{ display: "flex", alignItems: "center", gap: 8 }}>
                    <SeverityPill level="critical" large />
                    <span className="hud-live">LIVE</span>
                  </div>
                  <div className="hud-name">Stripe secret key</div>
                  <div className="hud-key">sk_live_<span className="dots">••••••••</span>x9Qa</div>
                  <div className="hud-caption">These characters are all AgentSafe stores. The rest of the key is never written down.</div>
                </div>
                <div className="hud-right">
                  <dl className="hud-grid" style={{ margin: 0 }}>
                    <dt>Can do</dt><dd>Everything in your Stripe account: charges, refunds, payouts</dd>
                    <dt>Mode</dt><dd>Live, from the <code>sk_live_</code> prefix</dd>
                    <dt>Found in</dt><dd>Claude Code transcript</dd>
                    <dt>File</dt><dd className="path">~/.claude/projects/shop-api/session.jsonl</dd>
                    <dt>Seen</dt><dd>Today, 21:49</dd>
                  </dl>
                  <div className="hud-actions">
                    <span className="hud-btn aqua">Rotate at Stripe ↗</span>
                    <span className="hud-btn ghost">Remove local copy</span>
                  </div>
                </div>
              </div>
              <div className="hud-warning">
                <Caution size="sm" />
                This key went to the model provider with the transcript. Removing the local copy helps; only rotating the key fixes it.
              </div>
            </div>
          </div>
        </section>

        {/* ── Where it looks ── */}
        <section id="sources" className="section" style={{ paddingLeft: 0, paddingRight: 0 }}>
          <div style={{ padding: "0 24px" }}>
            <SectionHead
              eyebrow="Where it looks"
              title="Scans the places your agents write things down"
              sub="Transcripts from Claude Code, Codex and Cursor, plus agent configs, shell history, .env files and the key files in your git history. Detection is by pattern: it knows key formats and .env variable names."
            />
          </div>
          <div className="sources">
            {[["Claude Code", "transcripts"], ["Codex", "sessions"], ["Cursor", "chats"]].map(([title, caption]) => (
              <div className="card source" key={title}>
                <div className="ico-folder" aria-hidden="true"><div className="tab" /><div className="body" /></div>
                <div className="source-title">{title}</div><div className="source-caption">{caption}</div>
              </div>
            ))}
            <div className="card source">
              <div className="ico-folder grey" aria-hidden="true"><div className="tab" /><div className="body" /></div>
              <div className="source-title">Agent configs</div><div className="source-caption">settings, MCP</div>
            </div>
            <div className="card source">
              <div className="ico-term" aria-hidden="true">&gt;_</div>
              <div className="source-title">Shell history</div><div className="source-caption">~/.zsh_history</div>
            </div>
            <div className="card source">
              <div className="ico-env" aria-hidden="true"><span>ENV</span></div>
              <div className="source-title">.env files</div><div className="source-caption">in your projects</div>
            </div>
            <div className="card source source-wide">
              <div className="ico-folder" aria-hidden="true"><div className="tab" /><div className="body" /></div>
              <div>
                <div className="source-title">Git history, pushed or not</div>
                <div className="source-caption">every past version of .env files, agent configs and shell history, in every commit</div>
                <p className="source-note">
                  A key deleted from a .env file is still in the commit that added it. AgentSafe reads .git directly, says
                  whether that commit was pushed and to which remote, and puts pushed keys higher on the rotation list.
                </p>
              </div>
            </div>
          </div>
          <div className="marquee">
            <div className="marquee-track">
              {[...formats, ...formats].map(([prefix, name], index) => (
                <span className="chip" key={index} aria-hidden={index >= formats.length || undefined}>
                  <code>{prefix}</code>{name}
                </span>
              ))}
            </div>
          </div>
        </section>

        {/* ── Watches continuously ── */}
        <section id="watch" className="section">
          <SectionHead
            eyebrow="Watches continuously"
            title="The shield turns red within seconds"
            sub="When a key lands in a transcript, the shield in your menu bar turns orange or red. An alert never opens the app by itself. You decide when to look."
          />
          <WatchDemo />
        </section>

        {/* ── The safe ── */}
        <section id="safe" className="section">
          <SectionHead
            eyebrow="Keeps keys in a safe"
            title="Touch ID to open it. Touch ID again for every key."
            sub="Opening the panel or the safe window asks for Touch ID, and reading a key back asks again, every time. AgentSafe tracks each key's age and expiry, and takes you straight to the page where it is managed when it is time to rotate."
            pills={["Age and expiry, per key", "Copy is safer than Show"]}
          />
          <SafeDemo />
        </section>

        {/* ── How the safe works ── */}
        <section id="how" className="section">
          <div className="how">
            <div>
              <div className="eyebrow">How the safe works</div>
              <h2 className="h2">Easy to fill. Hard to open. Unable to phone home.</h2>
              <p className="sub">
                Saving a key never needs the secret that opens the others. Opening the safe needs your master password or
                Touch ID. And the app has no way onto the network at all.
              </p>
              <div className="check-label">Check any build yourself</div>
              <div className="code-dark"><span className="prompt">%</span> codesign -d --entitlements - /Applications/AgentSafe.app</div>
            </div>
            <InfoWindow />
          </div>
        </section>

        {/* ── Command line ── */}
        <section id="cli" className="section">
          <SectionHead
            eyebrow="Starts projects without .env files"
            title="Delete the .env file. Keep the dev server."
            sub={<><code>agentsafe run -- npm run dev</code> hands the keys to your command after you approve with Touch ID. The helper ships inside the app, has no network code and never stores a key.</>}
          />
          <div className="frame graphite-frame">
            <div className="cli-terminal" role="img" aria-label="A terminal: agentsafe init writes the variable names to agentsafe.keys, then agentsafe run asks AgentSafe for approval.">
              <TitleBar title="shop-api — zsh — 80×24" variant="terminal" />
              <div className="terminal-body">
                <div><span className="prompt">shop-api %</span> agentsafe init</div>
                <div className="dim">Wrote agentsafe.keys with 3 names:</div>
                <div className="dim">&nbsp;&nbsp;STRIPE_SECRET_KEY</div>
                <div className="dim">&nbsp;&nbsp;OPENAI_API_KEY</div>
                <div className="dim">&nbsp;&nbsp;DATABASE_URL</div>
                <div><span className="prompt">shop-api %</span> agentsafe run -- npm run dev</div>
                <div className="dim">agentsafe: sent a request for 3 keys to AgentSafe…</div>
                <div className="waiting">agentsafe: AgentSafe is asking for your approval (Touch ID)…<span className="cursor" /></div>
              </div>
            </div>
            <div className="approval" role="img" aria-label="AgentSafe's approval prompt: a command wants three keys, listed by name, with Deny and Approve with Touch ID buttons.">
              <div style={{ display: "flex", gap: 14, alignItems: "flex-start" }}>
                <AppIcon size={52} />
                <div style={{ minWidth: 0, flex: 1 }}>
                  <div style={{ fontSize: 13, fontWeight: "bold", lineHeight: 1.35 }}>A command wants 3 keys from your safe.</div>
                  <div className="field-label">Command, as the requester describes it</div>
                  <div className="inset-field" style={{ marginTop: 4 }}>npm run dev</div>
                  <div className="field-label" style={{ marginTop: 10 }}>Keys</div>
                  <div className="key-list"><div>STRIPE_SECRET_KEY</div><div>OPENAI_API_KEY</div><div>DATABASE_URL</div></div>
                </div>
              </div>
              <div className="buttons">
                <span className="wbtn text-12">Deny</span>
                <span className="wbtn aqua text-12 throb" style={{ padding: "0 14px" }}>Approve with Touch ID</span>
              </div>
              <div className="footnote">Only keys switched on for agentsafe run can be requested.</div>
            </div>
          </div>

          <div className="cmd-list">
            <div className="list-head cmd-cols"><div>Command</div><div>What it does</div></div>
            <div className="cmd-row cmd-cols"><code>agentsafe init</code><span>Writes agentsafe.keys from the names in .env. Names only.</span></div>
            <div className="cmd-row cmd-cols"><code>agentsafe run -- npm run dev</code><span>Starts a command with those keys, after Touch ID.</span></div>
            <div className="cmd-row cmd-cols"><code>agentsafe run --keys A,B -- cmd</code><span>Or names the variables directly.</span></div>
          </div>

          <div className="handshake">
            <div className="handshake-title">The helper and the app meet in <code>~/.agentsafe/</code></div>
            <div className="steps">
              {[
                ["1", "The helper writes a request", "It names the command and the keys it wants."],
                ["2", "The app asks you", "Every key is listed. Nothing moves without Touch ID."],
                ["3", "The reply is sealed", "Encrypted to a key that exists only in the helper's memory, for that one request."],
              ].map(([n, title, text]) => (
                <div className="card step" key={n}>
                  <div className="num-orb" aria-hidden="true">{n}</div>
                  <div className="step-title">{title}</div>
                  <div className="step-text">{text}</div>
                </div>
              ))}
            </div>
          </div>

          <div className="duo">
            <div className="card feature-card">
              <div className="feature-eyebrow">Hardens Claude Code</div>
              <div className="feature-title">Deny rules for your secret files, added for you</div>
              <div className="snippet">{`"permissions": {
  "deny": [
    "Read(//**/.env)",
    "Read(//**/.env.local)",
    "Read(~/.ssh/**)",
    "Read(~/.aws/credentials)",
`}<span className="comment">{"    …and 8 more"}</span>{`
  ]
}`}</div>
              <div className="feature-note">Added to <span className="mono" style={{ fontSize: 12 }}>~/.claude/settings.json</span>, so they apply in every project. A seatbelt: the rules block Claude Code&apos;s file tools and plain shell reads such as cat. They do not stop a script from opening the file.</div>
            </div>
            <div className="card feature-card">
              <div className="feature-eyebrow">For AI agents</div>
              <div className="feature-title">A skill file you can hand to your agent</div>
              <div className="mini-doc">
                <div className="mini-doc-title"><a href={SKILL}>skills/agentsafe/SKILL.md</a></div>
                <div className="mini-doc-body">
                  <div>· Never read secret files.</div>
                  <div>· Move the project onto agentsafe run.</div>
                  <div>· Propose limits on your own access.</div>
                </div>
              </div>
              <div className="feature-note">Give it to Claude Code, Codex or Cursor so the agent works with the safe instead of around it.</div>
              <div style={{ marginTop: 18 }}><a className="btn btn-md btn-grey" href={SKILL}>Read the skill on GitHub</a></div>
            </div>
          </div>
        </section>

        {/* ── Limits ── */}
        <section id="limits" className="section tall">
          <div className="quote-card">
            <Caution size="lg" />
            <div className="quote">“A clean scan is good news, not proof.”</div>
            <div className="quote-rule" />
            <div className="quote-source">From the AgentSafe README, under <b>What it does not protect against</b></div>
          </div>
          <div className="limits">
            <SectionHead title="What it does not protect against" sub="Read this before you trust it with anything." />
            <div className="limit-grid">
              {limits.map(([title, text]) => (
                <div className="limit" key={title}>
                  <Caution size="md" />
                  <div><b>{title}</b><p>{text}</p></div>
                </div>
              ))}
            </div>
          </div>
        </section>

        {/* ── Pricing ── */}
        <section id="pricing" className="section tall">
          <SectionHead
            eyebrow="Pricing"
            title="Pay once, keep your Mac safe forever."
            sub="The signed app and the scan are free. A licence adds the clean-up and the watch. Or read the source and build it yourself."
          />
          <div className="plans">
            <div className="window plan">
              <TitleBar title="AgentSafe Licence" />
              <div className="plan-body">
                <div className="plan-id">
                  <AppIcon size={52} />
                  <div><b>AgentSafe for Mac</b><span>Lifetime licence · every Mac you own</span></div>
                </div>
                <div className="price"><strong>{price}</strong><span>once</span></div>
                <div className="ladder-note">
                  {!open
                    ? "Sales open soon."
                    : ladder.nextPriceCents
                      ? `${ladder.leftAtThisPrice} left at this price, then ${formatUSD(ladder.nextPriceCents)}. The price rises $1 every ${LADDER.salesPerStep} sales and stops at ${formatUSD(LADDER.capCents)}.`
                      : "Final price."}
                </div>
                <ol className="ladder" aria-label="Price steps">
                  {tiers.map((cents) => (
                    <li key={cents} className={cents < ladder.priceCents ? "past" : cents === ladder.priceCents ? "now" : undefined}>{formatUSD(cents)}</li>
                  ))}
                </ol>
                <div className="ticks">
                  {[
                    "The exact file and line of every leaked copy",
                    "Remove all local copies in one click",
                    "The menu bar shield that keeps watching",
                    "As many keys in the safe as you have",
                    "Rotation and expiry reminders",
                    "Every later version",
                  ].map((line) => (
                    <div key={line}><span className="check-orb" aria-hidden="true">✓</span>{line}</div>
                  ))}
                </div>
                <div className="plan-spacer" />
                {open ? (
                  <form action="/api/checkout" method="post">
                    <button type="submit" className="btn btn-md btn-aqua btn-block">Buy a licence for {price}</button>
                  </form>
                ) : (
                  <span className="btn btn-md btn-aqua btn-block" aria-disabled="true">Sales open soon</span>
                )}
                <div className="fine">VAT included where it applies. No account, no subscription.</div>
              </div>
            </div>

            <div className="window plan free">
              <TitleBar title="agentsafe — zsh" />
              <div className="build-terminal">
                <div>% git clone {REPO.replace("https://", "")}</div>
                <div>% cd agentsafe/app</div>
                <div>% swift test <span className="comment"># the test suite</span></div>
                <div>% ./scripts/build-app.sh <span className="comment"># dist/AgentSafe.app</span></div>
                <div>% open dist/AgentSafe.app</div>
              </div>
              <div className="free-body">
                <div className="free-price"><strong>Free</strong><span>download, or build from source</span></div>
                <p className="free-text">
                  Without a licence you still get the scan, every leaked key ranked with a link to rotate it, Claude Code
                  hardening, encrypted backup and three keys in the safe.
                </p>
                <p className="free-text">
                  Building needs macOS 14 and Xcode. Without a signing certificate the script signs ad hoc, which runs on
                  your own Mac. The source is under the Functional Source License.
                </p>
                <div className="flags">
                  <code>--selftest</code><span>Prints whether the sandbox and the network block are in effect.</span>
                  <code>--snapshot &lt;folder&gt;</code><span>Renders every screen to PNG with made-up data.</span>
                </div>
                <div className="repo">
                  <div><code>app/</code><span>The Mac app, core logic, tests and the CLI</span></div>
                  <div><code>web/</code><span>Landing page, checkout and licence page</span></div>
                  <div><code>shared/</code><span>Licence public key and a test licence</span></div>
                  <div><code>skills/</code><span>The skill file for AI agents</span></div>
                </div>
                <div className="repo-link"><a href={REPO}>Read the source on GitHub</a></div>
              </div>
            </div>
          </div>
        </section>

        {/* ── FAQ ── */}
        <section id="faq" className="section tall">
          <SectionHead eyebrow="FAQ" title="Plain answers" />
          <Faq items={faqs} />
        </section>

        {/* ── Final call ── */}
        <section className="final">
          <AppIcon size={112} className="final-icon" />
          <h2 className="h2">Put your keys back in the safe.</h2>
          <p className="sub">Everything happens on your Mac. Nothing it reads can leave it.</p>
          <div className="final-ctas">
            <DownloadButton url={downloadUrl} />
            <a className="btn btn-lg btn-grey" href="#limits">Read the limits</a>
          </div>
          <div className="final-note">macOS 14 Sonoma or later</div>
        </section>

        <footer className="footer">
          <div className="footer-inner">
            <div className="footer-brand">
              <AppIcon size={22} />
              <span><b>AgentSafe</b> · Runs on your Mac, and only on your Mac.</span>
            </div>
            <div className="footer-links">
              <a href="#how">How the safe works</a>
              <a href="#limits">Limits</a>
              <a href="#pricing">Pricing</a>
              <a href={REPO}>Source on GitHub</a>
            </div>
          </div>
        </footer>
      </div>
    </div>
  );
}
