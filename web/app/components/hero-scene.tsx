// The hero's glass dock and the MacBook showing a findings window. Both are decorative
// illustrations: the dock is hidden from screen readers, and the MacBook is described in one line.

import { AppIcon, Magnifier, SeverityPill, Shield, TrafficLights, shieldColours, type Severity } from "./chrome";
import { CalendarDate } from "./clock";

function Tile({ children, running, label }: { children: React.ReactNode; running?: boolean; label?: string }) {
  return (
    <div className="dock-item">
      {label && <div className="dock-label">{label}</div>}
      <div className="dock-tile">{children}</div>
      {running && <div className="dock-run" />}
    </div>
  );
}

function Document({ label, blue }: { label: string; blue?: boolean }) {
  return (
    <div className="di-doc">
      <div className="fold" />
      <div className="lines" />
      <div className={`label${blue ? " blue" : ""}`}>{label}</div>
    </div>
  );
}

export function Dock() {
  const now = new Date();
  return (
    <div className="dock" aria-hidden="true">
      <div className="dock-inner">
        <div className="dock-shelf" />
        <div className="dock-row">
          <Tile running><div className="di-folder"><div className="tab" /><div className="body" /></div></Tile>
          <Tile running>
            <div className="di-globe"><div className="meridian" /><div className="parallel" /><div className="equator" /><div className="axis" /></div>
          </Tile>
          <Tile><div className="di-mail"><div className="flap" /><div className="stripe" /></div></Tile>
          <Tile>
            <div className="di-cal">
              <CalendarDate month={now.toLocaleDateString("en-US", { month: "short" }).toUpperCase()} day={now.getDate()} />
            </div>
          </Tile>
          <Tile><div className="di-notes"><div className="binding" /></div></Tile>
          <Tile running label="AgentSafe"><AppIcon size="4.6em" /></Tile>
          <Tile running><div className="di-term"><div className="screen">&gt;_</div></div></Tile>
          <Tile>
            <div className="di-clock"><div className="hour" /><div className="minute" /><div className="pin" /></div>
          </Tile>
          <div className="dock-sep" />
          <Tile><Document label="ENV" /></Tile>
          <Tile><Document label="JSONL" blue /></Tile>
          <Tile><div className="di-trash"><div className="can" /><div className="rim" /></div></Tile>
        </div>
      </div>
    </div>
  );
}

type Row = {
  level: Severity;
  name: string;
  tag?: "LIVE" | "SANDBOX";
  masked: string;
  can: string;
  source: string;
  detail: string;
  when: string;
};

// Made-up findings. Severities and masks follow what the app really shows: AgentSafe
// stores the prefix up to the last dash or underscore, and the last four characters.
const rows: Row[] = [
  { level: "critical", name: "Stripe secret key", tag: "LIVE", masked: "sk_live_•••x9Qa", can: "Charges, refunds, payouts", source: "Claude Code", detail: "shop-api", when: "2 min" },
  { level: "critical", name: "GitHub token", masked: "ghp_•••8LmT", can: "Read and write your repositories", source: "Shell history", detail: "~/.zsh_history", when: "1 day" },
  { level: "high", name: "OpenAI project key", masked: "sk-proj-•••Hk2w", can: "Spend on your API account", source: "Codex", detail: "invoice-bot", when: "3 hr" },
  { level: "high", name: "Slack bot token", masked: "xoxb-•••Q1pe", can: "Post as your bot", source: "Cursor", detail: "support-tool", when: "1 wk" },
  { level: "medium", name: "AWS access key ID", masked: "AKIA•••7QFJ", can: "Half a credential; risky with its secret", source: ".env file", detail: "~/code/dash", when: "5 days" },
  { level: "low", name: "Stripe test key", tag: "SANDBOX", masked: "sk_test_•••3Rbd", can: "Test mode only", source: ".env.local", detail: "~/code/shop", when: "2 wk" },
];

function SidebarItem({ label, count, tone, selected }: { label: string; count: number; tone?: "red" | "orange"; selected?: boolean }) {
  return (
    <div className={`sidebar-item${selected ? " selected" : ""}`}>
      {label}
      <span className={`count${tone ? ` ${tone}` : ""}`}>{count}</span>
    </div>
  );
}

export function MacBook() {
  return (
    <div className="macbook" role="img" aria-label="An illustration of AgentSafe's findings: six leaked keys, worst first, starting with a live Stripe secret key found in a Claude Code transcript.">
      <div className="macbook-reflect">
        <div className="bezel">
          <div className="camera" />
          <div className="screen">
            <div className="screen-scroll">
              <div className="stage">
                <div className="aurora screen" />
                <div className="stars small" />

                <div className="screen-menubar">
                  <div className="small-dial" />
                  <b>AgentSafe</b><span>File</span><span>Edit</span><span>View</span><span>Window</span><span>Help</span>
                  <div className="spacer" />
                  <Shield colour={shieldColours.serious} width={14} height={16} />
                  <span>Fri 9:52 PM</span>
                  <Magnifier size={13} colour="#111" />
                </div>

                <div className="desktop-file">
                  <div className="doc"><span>ENV</span></div>
                  <span>.env</span>
                </div>

                <div className="window findings-window">
                  <div className="window-head">
                    <div className="titlebar"><TrafficLights />AgentSafe — Findings</div>
                    <div className="toolbar">
                      <span className="wbtn">↻ Scan Now</span>
                      <span className="toolbar-status"><span className="led" />Watching 5 sources</span>
                      <div style={{ flex: 1 }} />
                      <div className="search-field"><Magnifier size={10} colour="#777" />Search findings</div>
                    </div>
                  </div>
                  <div className="findings-body">
                    <div className="sidebar">
                      <div className="sidebar-head">▾ FINDINGS</div>
                      <SidebarItem label="All findings" count={14} selected />
                      <SidebarItem label="Critical" count={2} tone="red" />
                      <SidebarItem label="Leaked by agents" count={12} />
                      <div className="sidebar-head">▾ SOURCES</div>
                      <SidebarItem label="Claude Code" count={6} />
                      <SidebarItem label="Codex" count={3} />
                      <SidebarItem label="Cursor" count={2} />
                      <SidebarItem label="Shell history" count={1} />
                      <SidebarItem label=".env files" count={2} />
                      <div className="sidebar-head">▾ SAFE</div>
                      <SidebarItem label="Keys" count={5} />
                      <SidebarItem label="Expiring soon" count={1} tone="orange" />
                    </div>
                    <div className="findings-table">
                      <div className="list-head findings-cols">
                        <div className="sorted">Severity<span className="arrow">▼</span></div>
                        <div>Key</div>
                        <div>Can do</div>
                        <div>Found in</div>
                        <div style={{ justifyContent: "flex-end" }}>When</div>
                      </div>
                      {rows.map((row, index) => (
                        <div className={`findings-row findings-cols${index === 0 ? " selected" : ""}`} key={row.masked}>
                          <div><SeverityPill level={row.level} /></div>
                          <div>
                            <div className="name">
                              {row.name}{" "}
                              {row.tag && <span className={`tag ${row.tag === "LIVE" ? "tag-live" : "tag-sandbox"}`}>{row.tag}</span>}
                            </div>
                            <div className="masked">{row.masked}</div>
                          </div>
                          <div className="can">{row.can}</div>
                          <div>
                            <div className="ellipsis">{row.source}</div>
                            <div className="detail">{row.detail}</div>
                          </div>
                          <div className="when">{row.when}</div>
                        </div>
                      ))}
                    </div>
                  </div>
                  <div className="statusbar">6 of 14 findings · 2 critical · Keys stored masked · Network access: none</div>
                </div>
              </div>
            </div>
          </div>
        </div>
        <div className="hinge" />
      </div>
    </div>
  );
}
