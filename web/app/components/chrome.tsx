// Shared pieces of the Leopard look: window chrome, icons and small labels.
// All of it is drawn in CSS or simple SVG; no Apple artwork is used.

import type { CSSProperties, ReactNode } from "react";

export function TrafficLights({ inactive = false }: { inactive?: boolean }) {
  return (
    <div className="lights" aria-hidden="true">
      <span className="light red" />
      <span className={`light ${inactive ? "off" : "yellow"}`} />
      <span className={`light ${inactive ? "off" : "green"}`} />
    </div>
  );
}

/** A title bar on its own, for windows without a toolbar. */
export function TitleBar({ title, variant = "plain", inactive }: { title: ReactNode; variant?: "plain" | "terminal"; inactive?: boolean }) {
  return (
    <div className={`titlebar ${variant}`}>
      <TrafficLights inactive={inactive} />
      {title}
    </div>
  );
}

/**
 * The app's own icon. The PNG has a transparent margin around the rounded square, so the
 * image is drawn larger than `size` and centred: `size` is the visible size of the square.
 */
export function AppIcon({ size, className, style }: { size: number | string; className?: string; style?: CSSProperties }) {
  const box = typeof size === "number" ? `${size}px` : size;
  return (
    <span className={`app-icon ${className ?? ""}`} style={{ width: box, height: box, ...style }} aria-hidden="true">
      {/* eslint-disable-next-line @next/next/no-img-element */}
      <img src="/icon-512.png" alt="" />
    </span>
  );
}

export type Severity = "critical" | "high" | "medium" | "low";
const severityLabel: Record<Severity, string> = { critical: "Critical", high: "High", medium: "Medium", low: "Low" };

export function SeverityPill({ level, large }: { level: Severity; large?: boolean }) {
  return <span className={`sev sev-${level}${large ? " lg" : ""}`}>{severityLabel[level]}</span>;
}

/**
 * The menu bar shield, drawn the way the app draws it: the outline carries the status,
 * with a small lock inside. Green when nothing has leaked, orange or red when something has.
 */
export const shieldColours = { clear: "#34c759", leaked: "#ff9500", serious: "#ff3b30" } as const;

export function Shield({ colour, width = 15, height = 17, lock = "#111", className }: { colour: string; width?: number; height?: number; lock?: string; className?: string }) {
  return (
    <svg className={className} width={width} height={height} viewBox="0 0 24 24" aria-hidden="true">
      <path d="M12 2.2l8 3v6c0 5-3.4 9.2-8 10.9-4.6-1.7-8-5.9-8-10.9v-6z" fill="none" stroke={colour} strokeWidth="2.4" strokeLinejoin="round" />
      <rect x="8.6" y="11" width="6.8" height="5.4" rx="1" fill={lock} />
      <path d="M10 11V9.6a2 2 0 0 1 4 0V11" fill="none" stroke={lock} strokeWidth="1.5" />
    </svg>
  );
}

export function Magnifier({ size = 14, colour = "currentColor" }: { size?: number; colour?: string }) {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" aria-hidden="true">
      <circle cx="6.5" cy="6.5" r="4.5" fill="none" stroke={colour} strokeWidth="1.8" />
      <path d="M10 10l4.5 4.5" stroke={colour} strokeWidth="2" />
    </svg>
  );
}

export function Caution({ size }: { size: "sm" | "md" | "lg" }) {
  return <div className={`caution ${size}`} aria-hidden="true">!</div>;
}

export function SectionHead({ eyebrow, title, sub, pills }: { eyebrow?: string; title: ReactNode; sub?: ReactNode; pills?: string[] }) {
  return (
    <div className="section-head">
      {eyebrow && <div className="eyebrow">{eyebrow}</div>}
      <h2 className="h2">{title}</h2>
      {sub && <p className="sub">{sub}</p>}
      {pills && (
        <div className="pills">
          {pills.map((p) => <span className="pill" key={p}>{p}</span>)}
        </div>
      )}
    </div>
  );
}

/** A download button that becomes a disabled one when there is nothing to download yet. */
export function DownloadButton({ url, size = "lg", label = "Download for Mac" }: { url?: string; size?: "lg" | "md"; label?: string }) {
  if (!url) return <span className={`btn btn-${size} btn-aqua`} aria-disabled="true">Download opens soon</span>;
  return <a className={`btn btn-${size} btn-aqua`} href={url}>{label}</a>;
}
