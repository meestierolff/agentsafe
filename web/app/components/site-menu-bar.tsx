import { Clock } from "./clock";
import { Magnifier, Shield, shieldColours } from "./chrome";

/**
 * The site's navigation, styled as a Leopard menu bar. A safe dial takes the place of the
 * Apple logo. `base` is "" on the home page and "/" elsewhere, so the section links work.
 */
export function SiteMenuBar({ base = "", downloadUrl }: { base?: string; downloadUrl?: string }) {
  const at = (id: string) => `${base}#${id}`;
  return (
    <header className="menubar">
      <div className="menubar-inner">
        <a className="menu-item glyph" href={at("top")} aria-label="AgentSafe home">
          <span className="dial" aria-hidden="true"><span /></span>
        </a>
        <a className="menu-item bold" href={at("top")}>AgentSafe</a>
        <nav className="menu-links" aria-label="Sections">
          <a className="menu-item" href={at("finds")}>Features</a>
          <a className="menu-item" href={at("safe")}>The Safe</a>
          <a className="menu-item" href={at("cli")}>Command Line</a>
          <a className="menu-item" href={at("limits")}>Limits</a>
          <a className="menu-item" href={at("pricing")}>Pricing</a>
          <a className="menu-item" href={at("faq")}>Help</a>
        </nav>
        <div className="menu-right">
          <a className="menu-item bold" href={downloadUrl ?? at("pricing")}>Download for Mac</a>
          <a className="menu-item menu-shield" href={at("watch")} aria-label="How the menu bar shield works">
            <Shield colour={shieldColours.clear} width={15} height={17} />
          </a>
          <div className="menu-item menu-clock"><Clock /></div>
          <a className="menu-item" href={at("faq")} aria-label="Help"><Magnifier /></a>
        </div>
      </div>
    </header>
  );
}
