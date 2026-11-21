import type { Metadata, Viewport } from "next";
import "./globals.css";

const site = process.env.SITE_URL ?? "https://safeagent.live";

export const metadata: Metadata = {
  metadataBase: new URL(site),
  title: "AgentSafe: a smoke detector and a safe for your API keys",
  description:
    "A Mac app that sits in your menu bar or notch. It warns you when an AI agent leaves an API key in a transcript, and keeps your keys where agents cannot read them. Runs entirely on your Mac.",
  openGraph: {
    title: "AgentSafe: a smoke detector and a safe for your API keys",
    description: "Find the keys your AI agents already leaked. Keep the rest behind Touch ID. Nothing leaves your Mac.",
    images: [{ url: "/screens/notch-alert.png", width: 1280, height: 960, alt: "The AgentSafe notch panel showing a leaked Anthropic key" }],
    type: "website",
  },
  twitter: { card: "summary_large_image" },
};

export const viewport: Viewport = { width: "device-width", initialScale: 1, themeColor: "#14305c" };

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
