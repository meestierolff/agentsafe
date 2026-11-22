"use client";

// The interactive parts of the page. All data here is made up, and every "key" is an
// obviously fake string.

import { useEffect, useRef, useState, type ReactNode } from "react";
import { AppIcon, Shield, TrafficLights, shieldColours } from "./chrome";

/* ── Watch demo ─────────────────────────────────────────────── */

// Mirrors the app: a medium-severity leak turns the shield orange, a high or critical
// one turns it red. The notification names the kind of key and where it was found, never
// which of your stored keys it is, and it never opens the app.
const alertStates = [
  { label: "All clear", colour: shieldColours.clear, title: "", body: "" },
  {
    label: "A Google key lands",
    colour: shieldColours.leaked,
    title: "Google key leaked",
    body: "Found in Claude Code transcripts. Open AgentSafe to see it and rotate.",
  },
  {
    label: "A live Stripe key lands",
    colour: shieldColours.serious,
    title: "Stripe key leaked",
    body: "Found in Claude Code transcripts. Open AgentSafe to see it and rotate.",
  },
];

export function WatchDemo() {
  const [state, setState] = useState(2);
  const current = alertStates[state];
  return (
    <>
      <div className="watch-stage" role="img" aria-label={state === 0
        ? "An agent session reading a .env file. The menu bar shield is green: nothing has leaked."
        : `An agent session printed a key into its transcript. The menu bar shield turned ${state === 1 ? "orange" : "red"} and a notification says: ${current.title}.`}>
        <div className="aurora screen" />
        <div className="stars small" />
        <div className="screen-menubar">
          <b>Terminal</b><span>Shell</span><span className="optional">Edit</span><span className="optional">View</span>
          <div className="spacer" />
          <Shield className="shield" colour={current.colour} />
          <span>Fri 9:52 PM</span>
        </div>
        <div className="agent-terminal">
          <div className="titlebar terminal"><TrafficLights />shop-api — agent session</div>
          <div className="terminal-body">
            <div><span className="prompt">&gt;</span> why does checkout fail locally?</div>
            <div className="dim">Reading .env to check the payment config…</div>
            <div className="plain">PORT=3000</div>
            <div className="plain">NODE_ENV=development</div>
            {state >= 1 && <div className="hit orange">GOOGLE_API_KEY=AIza••••••••••••••••3kQw</div>}
            {state >= 2 && <div className="hit red">STRIPE_SECRET_KEY=sk_live_51H••••••••••x9Qa</div>}
            <div className="faint">transcript saved → ~/.claude/projects/shop-api/session.jsonl</div>
          </div>
        </div>
        <div className="growl" data-shown={state > 0}>
          <AppIcon size={34} />
          <div style={{ minWidth: 0 }}>
            <div className="growl-title">{current.title}</div>
            <div className="growl-body">{current.body}</div>
          </div>
        </div>
      </div>
      <div className="segmented-wrap">
        <div className="segmented-label" id="watch-try">Try it</div>
        <div className="segmented" role="group" aria-labelledby="watch-try">
          {alertStates.map((s, index) => (
            <button type="button" key={s.label} className="segment" aria-pressed={index === state} onClick={() => setState(index)}>
              {s.label}
            </button>
          ))}
        </div>
      </div>
    </>
  );
}

/* ── Safe demo ──────────────────────────────────────────────── */

type DemoKey = { name: string; provider: string; age: string; rotate: boolean; expires: string; soon?: boolean; value: string };

const demoKeys: DemoKey[] = [
  { name: "STRIPE_SECRET_KEY", provider: "Stripe", age: "142 days", rotate: true, expires: "No expiry", value: "sk_live_51H_demo_not_a_real_key_x9Qa" },
  { name: "OPENAI_API_KEY", provider: "OpenAI", age: "31 days", rotate: false, expires: "No expiry", value: "sk-proj-demo-not-a-real-key-Hk2w" },
  { name: "ANTHROPIC_API_KEY", provider: "Anthropic", age: "12 days", rotate: false, expires: "No expiry", value: "sk-ant-demo-not-a-real-key-a9Fq" },
  { name: "GITHUB_TOKEN", provider: "GitHub", age: "88 days", rotate: true, expires: "In 2 days", soon: true, value: "github_pat_demo_not_a_real_key_8LmT" },
  { name: "DATABASE_URL", provider: "Postgres", age: "210 days", rotate: true, expires: "No expiry", value: "postgres://demo:not-real@localhost/shop" },
];

type Sheet = { key: DemoKey; action: "copy" | "show"; view: "ask" | "copy" | "show" };

export function SafeDemo() {
  const [allow, setAllow] = useState<Record<string, boolean>>({
    STRIPE_SECRET_KEY: true, OPENAI_API_KEY: true, ANTHROPIC_API_KEY: false, GITHUB_TOKEN: false, DATABASE_URL: true,
  });
  const [sheet, setSheet] = useState<Sheet | null>(null);
  const [phase, setPhase] = useState<"in" | "out">("out");
  const timers = useRef<ReturnType<typeof setTimeout>[]>([]);

  const clear = () => {
    timers.current.forEach(clearTimeout);
    timers.current = [];
  };
  const later = (fn: () => void, ms: number) => timers.current.push(setTimeout(fn, ms));
  useEffect(() => clear, []);

  const close = () => {
    clear();
    setPhase("out");
    later(() => setSheet(null), 320);
  };

  const grant = (current: Sheet) => {
    clear();
    setSheet({ ...current, view: current.action });
    if (current.action === "copy") later(close, 2400);
  };

  const open = (key: DemoKey, action: "copy" | "show") => {
    clear();
    const next: Sheet = { key, action, view: "ask" };
    setSheet(next);
    setPhase("out");
    later(() => setPhase("in"), 30);
    later(() => grant(next), 1900);
  };

  return (
    <div className="window safe-window" aria-label="A demo of the safe window. Copy and Show ask for Touch ID.">
      <div className="window-head">
        <div className="titlebar"><TrafficLights />Safe</div>
        <div className="toolbar">
          <span className="toolbar-status"><span className="led" />Opened with Touch ID</span>
          <div style={{ flex: 1 }} />
          <span className="wbtn">+ Add Key</span>
        </div>
      </div>
      <div className="sheet-host">
        {sheet && (
          <div className="sheet" data-phase={phase} role="dialog" aria-live="polite" aria-label="Touch ID">
            {sheet.view === "ask" && (
              <>
                <div style={{ display: "flex", gap: 14, alignItems: "flex-start" }}>
                  <button type="button" className="fingerprint" aria-label="Touch the sensor" title="Touch the sensor" onClick={() => grant(sheet)} />
                  <div style={{ minWidth: 0 }}>
                    <div className="sheet-title">Touch ID to read <code>{sheet.key.name}</code></div>
                    <div className="sheet-text">The safe is open, and AgentSafe still asks. Every read, every time.</div>
                  </div>
                </div>
                <div style={{ marginTop: 14, display: "flex", justifyContent: "flex-end" }}>
                  <button type="button" className="wbtn text-12" onClick={close}>Cancel</button>
                </div>
              </>
            )}
            {sheet.view === "copy" && (
              <div style={{ display: "flex", gap: 14, alignItems: "center" }}>
                <div className="done-orb" aria-hidden="true">✓</div>
                <div>
                  <div className="sheet-title">Copied <code>{sheet.key.name}</code></div>
                  <div className="sheet-text">Nothing appeared on screen. The clipboard clears in 30 seconds.</div>
                </div>
              </div>
            )}
            {sheet.view === "show" && (
              <>
                <div className="sheet-title"><code>{sheet.key.name}</code></div>
                <div className="revealed">{sheet.key.value}</div>
                <div className="reveal-warning">An agent that takes screenshots can capture what is on screen. Copy is safer than Show.</div>
                <div style={{ marginTop: 12, display: "flex", justifyContent: "flex-end" }}>
                  <button type="button" className="wbtn aqua text-12" onClick={close}>Hide</button>
                </div>
              </>
            )}
          </div>
        )}
        <div style={{ overflowX: "auto" }}>
          <div className="safe-table">
            <div className="list-head safe-cols">
              <div className="sorted">Name<span className="arrow">▲</span></div>
              <div>Age</div>
              <div>Expires</div>
              <div className="mono" style={{ fontSize: 10 }}>agentsafe run</div>
              <div />
            </div>
            {demoKeys.map((key, index) => {
              const on = !!allow[key.name];
              return (
                <div className={`safe-row safe-cols${index % 2 ? " alt" : ""}`} key={key.name}>
                  <div>
                    <div className="key-name ellipsis">{key.name}</div>
                    <div className="provider">{key.provider}</div>
                  </div>
                  <div>
                    <div>{key.age}</div>
                    {key.rotate && <span className="rotate">Rotate at {key.provider} ↗</span>}
                  </div>
                  <div className={key.soon ? "soon" : "no-expiry"}>{key.expires}</div>
                  <div>
                    <button type="button" className="toggle" role="checkbox" aria-checked={on} aria-label={`Commands may use ${key.name}`}
                      onClick={() => setAllow((a) => ({ ...a, [key.name]: !a[key.name] }))}>
                      <span className={`aqua-check ${on ? "on" : "off"}`}>{on ? "✓" : ""}</span>
                      {on ? "On" : "Off"}
                    </button>
                  </div>
                  <div className="actions">
                    <button type="button" className="wbtn size-20" onClick={() => open(key, "copy")}>Copy</button>
                    <button type="button" className="wbtn size-20" onClick={() => open(key, "show")}>Show</button>
                  </div>
                </div>
              );
            })}
            <div className="safe-spacer" />
          </div>
        </div>
      </div>
      <div className="statusbar">5 keys · 1 expires soon · Try Copy or Show</div>
    </div>
  );
}

/* ── Get Info window ────────────────────────────────────────── */

function Disclosure({ title, open, onToggle, divided, children, id }: { title: string; open: boolean; onToggle: () => void; divided?: boolean; children: ReactNode; id: string }) {
  return (
    <>
      <button type="button" className={`disclosure${divided ? " divided" : ""}`} aria-expanded={open} aria-controls={id} onClick={onToggle}>
        <span className="tri" aria-hidden="true">▶</span>{title}
      </button>
      {open && <div className="disclosure-panel" id={id}>{children}</div>}
    </>
  );
}

export function InfoWindow() {
  const [open, setOpen] = useState({ save: true, unlock: true, net: true });
  const flip = (key: keyof typeof open) => setOpen((o) => ({ ...o, [key]: !o[key] }));
  return (
    <div className="window info-window">
      <div className="titlebar plain" style={{ borderBottomColor: "#6a6a6a" }}><TrafficLights inactive />safe.json Info</div>
      <div className="info-head">
        <AppIcon size={40} />
        <div>
          <div style={{ fontSize: 13, fontWeight: "bold" }}>safe.json</div>
          <div style={{ fontSize: 11, color: "#666", marginTop: 2 }}>Your safe file · 5 keys</div>
        </div>
      </div>
      <div className="info-body">
        <Disclosure id="info-save" title="Saving a key:" open={open.save} onToggle={() => flip("save")}>
          Each key is encrypted to a public key stored in the safe file, so saving a key never requires the secret that opens the others.
        </Disclosure>
        <Disclosure id="info-open" title="Opening the safe:" open={open.unlock} onToggle={() => flip("unlock")} divided>
          <div>The matching private key is never stored in the clear. It is wrapped twice:</div>
          <div className="wrap-cards">
            <div className="wrap-card"><b>Master password</b><span>PBKDF2, 600,000 rounds</span></div>
            <div className="wrap-card"><b>Secure Enclave key</b><span>used by macOS only after Touch ID</span></div>
          </div>
        </Disclosure>
        <Disclosure id="info-net" title="Network:" open={open.net} onToggle={() => flip("net")} divided>
          Sandboxed without <span className="mono" style={{ fontSize: 10.5, wordBreak: "break-all" }}>com.apple.security.network.client</span>, so macOS blocks every connection it attempts.
        </Disclosure>
      </div>
    </div>
  );
}

/* ── FAQ ────────────────────────────────────────────────────── */

export function Faq({ items }: { items: { q: string; a: ReactNode }[] }) {
  const [openIndex, setOpenIndex] = useState(0);
  return (
    <div className="faq">
      {items.map((item, index) => {
        const open = openIndex === index;
        return (
          <div className={`faq-item${open ? " open" : ""}`} key={item.q}>
            <button type="button" className="faq-q" aria-expanded={open} aria-controls={`faq-${index}`}
              onClick={() => setOpenIndex(open ? -1 : index)}>
              <span className="tri" aria-hidden="true">▶</span>
              <b>{item.q}</b>
            </button>
            {open && <div className="faq-a" id={`faq-${index}`}>{item.a}</div>}
          </div>
        );
      })}
    </div>
  );
}
