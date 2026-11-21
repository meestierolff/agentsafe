// Talks to Stripe's REST API directly. Three calls are all this site needs, so there is
// no SDK to keep up to date.
//
// Stripe is also the only record of sales. There is no database: the site stores no
// customer emails, and the sale count for the price ladder comes from Stripe itself.

import { createHash, createHmac, timingSafeEqual } from "node:crypto";
import { LADDER } from "./pricing.mjs";

const API = "https://api.stripe.com/v1";
export const SKU = "agentsafe-mac";

/**
 * Sales open only when there is a payment key and a build to download. Taking money for
 * an app nobody can install yet would be the wrong order.
 */
export function salesAreOpen() {
  return Boolean(process.env.STRIPE_SECRET_KEY && process.env.DOWNLOAD_URL);
}

async function call(path, { method = "GET", params, revalidate } = {}) {
  const key = process.env.STRIPE_SECRET_KEY;
  if (!key) throw new Error("Stripe is not configured.");
  const body = params ? new URLSearchParams(params) : undefined;
  const url = method === "GET" && body ? `${API}${path}?${body}` : `${API}${path}`;
  const response = await fetch(url, {
    method,
    headers: { Authorization: `Bearer ${key}`, ...(method === "POST" ? { "Content-Type": "application/x-www-form-urlencoded" } : {}) },
    body: method === "POST" ? body : undefined,
    ...(revalidate === undefined ? { cache: "no-store" } : { next: { revalidate } }),
  });
  const json = await response.json();
  if (!response.ok) throw new Error(`Stripe ${path} failed: ${json?.error?.message ?? response.status}`);
  return json;
}

/**
 * How many licences have been paid for. The ladder stops rising at 25 sales, so one
 * page of 100 sessions is always enough to price the next sale correctly.
 */
export async function countPaidSales({ revalidate } = {}) {
  // Past this many sales the price is at its cap, so counting further changes nothing.
  const enough = Math.ceil((LADDER.capCents - LADDER.startCents) / LADDER.stepCents) * LADDER.salesPerStep;
  let count = 0;
  let startingAfter;
  // Walk back through the account's sessions. If the Stripe account also sells other
  // things, AgentSafe sales may not be on the first page, and missing them would lower
  // the price. Twenty pages (2,000 sessions) is a generous bound for one request.
  for (let pageNumber = 0; pageNumber < 20; pageNumber++) {
    const params = { status: "complete", limit: "100", ...(startingAfter ? { starting_after: startingAfter } : {}) };
    const page = await call("/checkout/sessions", { params, revalidate });
    count += page.data.filter((s) => s.payment_status === "paid" && s.metadata?.sku === SKU).length;
    if (count >= enough || !page.has_more || page.data.length === 0) break;
    startingAfter = page.data[page.data.length - 1].id;
  }
  return count;
}

export async function createCheckout({ priceCents, origin }) {
  return call("/checkout/sessions", {
    method: "POST",
    params: {
      mode: "payment",
      "line_items[0][quantity]": "1",
      "line_items[0][price_data][currency]": "usd",
      "line_items[0][price_data][unit_amount]": String(priceCents),
      // Tax-inclusive: the buyer pays exactly the price shown on the page, and any VAT is
      // taken out of it. Consumer prices in the EU must be shown with VAT included.
      "line_items[0][price_data][tax_behavior]": "inclusive",
      ...(process.env.STRIPE_PRODUCT_ID
        ? { "line_items[0][price_data][product]": process.env.STRIPE_PRODUCT_ID }
        : { "line_items[0][price_data][product_data][name]": "AgentSafe for Mac, lifetime licence" }),
      // Stripe Tax works out the VAT or sales tax from the buyer's location.
      ...(process.env.STRIPE_AUTOMATIC_TAX === "off" ? {} : { "automatic_tax[enabled]": "true" }),
      "metadata[sku]": SKU,
      "metadata[price_cents]": String(priceCents),
      success_url: `${origin}/thanks?session_id={CHECKOUT_SESSION_ID}`,
      cancel_url: `${origin}/#price`,
    },
  });
}

/** The paid session behind a thank-you link, or null when it is not a paid AgentSafe purchase. */
export async function paidSession(sessionId) {
  if (!/^cs_[A-Za-z0-9_]+$/.test(sessionId ?? "")) return null;
  try {
    const session = await call(`/checkout/sessions/${sessionId}`);
    return session.payment_status === "paid" && session.metadata?.sku === SKU ? session : null;
  } catch {
    return null;
  }
}

/** A stable licence id that does not reveal the Stripe session id. */
export function licenseIdFor(sessionId) {
  return `lic_${createHash("sha256").update(sessionId).digest("hex").slice(0, 16)}`;
}

/**
 * Checks that a webhook call really came from Stripe, and returns the event.
 *
 * Stripe signs `<timestamp>.<body>` with the endpoint's secret. Anyone can find the URL
 * of a webhook, so an unsigned or wrongly signed call is ignored, and so is one whose
 * timestamp is more than five minutes old (a recorded call being replayed).
 *
 * @returns the parsed event, or null when the call should not be trusted.
 */
export function verifyWebhook(rawBody, signatureHeader, secret, nowSeconds = Math.floor(Date.now() / 1000)) {
  if (!secret || !signatureHeader) return null;
  const parts = String(signatureHeader).split(",").map((part) => part.trim().split("="));
  const timestamp = Number(parts.find(([name]) => name === "t")?.[1]);
  const candidates = parts.filter(([name]) => name === "v1").map(([, value]) => value);
  if (!Number.isFinite(timestamp) || Math.abs(nowSeconds - timestamp) > 300) return null;
  const expected = Buffer.from(createHmac("sha256", secret).update(`${timestamp}.${rawBody}`).digest("hex"));
  const genuine = candidates.some((candidate) => {
    const given = Buffer.from(String(candidate));
    // Compared in constant time, so the response time reveals nothing about the signature.
    return given.length === expected.length && timingSafeEqual(given, expected);
  });
  if (!genuine) return null;
  try {
    return JSON.parse(rawBody);
  } catch {
    return null;
  }
}

/** True for a paid AgentSafe checkout. The Stripe account also carries other products. */
export function isAgentSafeSale(event) {
  const session = event?.data?.object;
  const completed = event?.type === "checkout.session.completed" || event?.type === "checkout.session.async_payment_succeeded";
  return Boolean(completed && session?.metadata?.sku === SKU && session?.payment_status === "paid");
}
