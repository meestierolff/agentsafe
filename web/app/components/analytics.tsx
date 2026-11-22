"use client";

import { Analytics, type BeforeSendEvent } from "@vercel/analytics/next";

/**
 * Vercel Web Analytics: page views without cookies.
 *
 * Every query parameter is dropped before an event leaves the browser, except the
 * utm_* tags that say which post or link a visitor came from. The thanks page URL
 * carries a Stripe checkout session ID that reveals the buyer's licence key, so this
 * is an allowlist: a parameter added later is dropped until someone decides otherwise.
 */
export function keepOnlyCampaignTags(event: BeforeSendEvent): BeforeSendEvent {
  const url = new URL(event.url);
  for (const name of [...url.searchParams.keys()]) {
    if (!name.toLowerCase().startsWith("utm_")) url.searchParams.delete(name);
  }
  url.hash = "";
  return { ...event, url: url.toString() };
}

export function SiteAnalytics() {
  return <Analytics beforeSend={keepOnlyCampaignTags} />;
}
