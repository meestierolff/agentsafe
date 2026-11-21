// A drawing of the app's notch panel, made of HTML so it stays sharp at any size.
// It is a picture, not a control: screen readers get one sentence instead.

const keys = [
  { name: "Anthropic production", state: "Leaked. Rotate now", tone: "bad", lamp: "red", preview: "sk-ant-…N4MH" },
  { name: "OpenAI side project", state: "Rotation 41 days overdue", tone: "bad", lamp: "red", preview: "sk-proj-…Zk9q" },
  { name: "GitHub deploy token", state: "Expires in 8 days", tone: "soon", lamp: "amber", preview: "ghp_…b2C3" },
  { name: "Stripe live", state: "Rotate in 65 days", tone: "", lamp: "green", preview: "sk_live_…C39H" },
];

export function NotchDemo() {
  return (
    <div className="notch-stage">
      <div className="notch" role="img" aria-label="The AgentSafe panel open below the MacBook notch. Its display reads 1 leak, 6 keys, 2 to rotate, and a red banner says an Anthropic key was found in a Claude Code transcript.">
        <div className="faceplate" aria-hidden="true">
          <div className="lcd">
            <span className="seg alarm"><b>1</b><span>LEAK</span></span>
            <span className="seg"><b>6</b><span>KEYS</span></span>
            <span className="seg warn"><b>2</b><span>TO ROTATE</span></span>
            <span className="tail">WATCHING</span>
          </div>
          <div className="alert">
            <span className="lamp red" />
            <span>
              <strong>Anthropic key leaked</strong>
              Found in a Claude Code transcript. It is your Anthropic production. Rotate it.
            </span>
          </div>
          <div className="paste">Paste a new key here (⌘V)</div>
          <div className="keys">
            {keys.map((key) => (
              <div className="key" key={key.name}>
                <span className={`lamp ${key.lamp}`} />
                <span>
                  <span className="name">{key.name}</span>
                  <br />
                  <span className={`state ${key.tone}`}>{key.state}</span>
                </span>
                <code>{key.preview}</code>
                <span className="gel plain small">Copy</span>
              </div>
            ))}
          </div>
          <div className="foot">
            <span className="gel plain small">Scan now</span>
            <span className="gel plain small">Open safe</span>
            <span className="note">Copying needs Touch ID</span>
          </div>
        </div>
      </div>
    </div>
  );
}
