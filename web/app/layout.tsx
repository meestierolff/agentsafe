import type { Metadata, Viewport } from "next";
import { Source_Sans_3 } from "next/font/google";
import "./globals.css";

const site = process.env.SITE_URL ?? "https://safeagent.live";

// Source Sans stands in for Myriad, the face Apple's marketing used in 2007.
const display = Source_Sans_3({ subsets: ["latin"], weight: ["400", "600", "700", "800"], variable: "--font-display", display: "swap" });

export const metadata: Metadata = {
  metadataBase: new URL(site),
  title: "AgentSafe: keys belong in a safe, not in a transcript",
  description:
    "A Mac app that finds the API keys your AI agents left in transcripts, shell history and .env files, ranks them by how dangerous they are, and keeps your keys behind Touch ID. Runs entirely on your Mac.",
  openGraph: {
    title: "AgentSafe: keys belong in a safe, not in a transcript",
    description: "Find the keys your AI agents already leaked. Keep the rest behind Touch ID. Nothing leaves your Mac.",
    images: [{ url: "/og.png", width: 1200, height: 630, alt: "AgentSafe: keys belong in a safe, not in a transcript." }],
    type: "website",
  },
  twitter: { card: "summary_large_image" },
};

export const viewport: Viewport = { width: "device-width", initialScale: 1, themeColor: "#e9e9ee" };

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={display.variable}>
      <body>{children}</body>
    </html>
  );
}
