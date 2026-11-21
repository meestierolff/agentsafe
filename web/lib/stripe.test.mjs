import test from "node:test";
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { SKU, countPaidSales, createCheckout, paidSession, salesAreOpen, verifyWebhook } from "./stripe.mjs";

// Replaces the network with canned Stripe pages for one test.
function withStripePages(pages, run) {
  const original = globalThis.fetch;
  const previousKey = process.env.STRIPE_SECRET_KEY;
  const requested = [];
  process.env.STRIPE_SECRET_KEY = "test-key-not-real";
  globalThis.fetch = async (url) => {
    requested.push(String(url));
    const page = pages[Math.min(requested.length - 1, pages.length - 1)];
    return { ok: true, status: 200, json: async () => page };
  };
  return run(requested).finally(() => {
    globalThis.fetch = original;
    if (previousKey === undefined) delete process.env.STRIPE_SECRET_KEY;
    else process.env.STRIPE_SECRET_KEY = previousKey;
  });
}

const session = (id, overrides = {}) => ({ id, payment_status: "paid", metadata: { sku: SKU }, ...overrides });
const otherProduct = (n) => Array.from({ length: n }, (_, i) => session(`cs_other_${i}`, { metadata: { sku: "something-else" } }));

test("only paid AgentSafe sessions count as sales", async () => {
  const page = {
    has_more: false,
    data: [session("cs_1"), session("cs_2"), session("cs_3", { payment_status: "unpaid" }), ...otherProduct(4), session("cs_4", { metadata: {} })],
  };
  await withStripePages([page], async () => assert.equal(await countPaidSales(), 2));
});

test("sales are still found when another product fills the first page", async () => {
  // On a Stripe account shared with other products, AgentSafe sales may not be among the
  // latest 100 sessions. Missing them would push the price back down.
  const first = { has_more: true, data: otherProduct(100) };
  const second = { has_more: false, data: [...Array.from({ length: 7 }, (_, i) => session(`cs_as_${i}`)), ...otherProduct(10)] };
  await withStripePages([first, second], async (requested) => {
    assert.equal(await countPaidSales(), 7);
    assert.equal(requested.length, 2);
    assert.match(requested[1], /starting_after=cs_other_99/);
  });
});

test("counting stops once the price can no longer change", async () => {
  const full = { has_more: true, data: Array.from({ length: 100 }, (_, i) => session(`cs_as_${i}`)) };
  await withStripePages([full, full, full], async (requested) => {
    assert.ok((await countPaidSales()) >= 25);
    assert.equal(requested.length, 1, "25 sales already put the price at its cap");
  });
});

test("a thank-you link with a malformed id never reaches Stripe", async () => {
  await withStripePages([{}], async (requested) => {
    assert.equal(await paidSession("../../v1/customers"), null);
    assert.equal(await paidSession(undefined), null);
    assert.equal(requested.length, 0);
  });
});

// ── Webhook signatures ─────────────────────────────────────────────

const secret = "whsec_" + "test_only_not_a_real_secret";
const sign = (body, timestamp, key = secret) => `t=${timestamp},v1=${createHmac("sha256", key).update(`${timestamp}.${body}`).digest("hex")}`;
const now = 1_800_000_000;
const body = JSON.stringify({ id: "evt_1", type: "checkout.session.completed", data: { object: { id: "cs_1", payment_status: "paid", metadata: { sku: SKU } } } });

test("an event signed by Stripe is accepted", () => {
  assert.equal(verifyWebhook(body, sign(body, now), secret, now)?.id, "evt_1");
});

test("a changed body, a wrong secret or a missing header is rejected", () => {
  assert.equal(verifyWebhook(body.replace("cs_1", "cs_2"), sign(body, now), secret, now), null);
  assert.equal(verifyWebhook(body, sign(body, now, "whsec_" + "someone_elses"), secret, now), null);
  assert.equal(verifyWebhook(body, "", secret, now), null);
  assert.equal(verifyWebhook(body, null, secret, now), null);
  assert.equal(verifyWebhook(body, sign(body, now), "", now), null, "no secret configured means nothing verifies");
});

test("an old event cannot be replayed", () => {
  assert.equal(verifyWebhook(body, sign(body, now - 3600), secret, now), null);
});

test("a second signature in the header is accepted during a secret rollover", () => {
  const header = `t=${now},v1=${"0".repeat(64)},v1=${sign(body, now).split("v1=")[1]}`;
  assert.equal(verifyWebhook(body, header, secret, now)?.id, "evt_1");
});

// ── Checkout ───────────────────────────────────────────────────────

test("checkout charges the given price, tax included, for the AgentSafe product", async () => {
  const original = globalThis.fetch;
  const saved = { key: process.env.STRIPE_SECRET_KEY, product: process.env.STRIPE_PRODUCT_ID };
  process.env.STRIPE_SECRET_KEY = "test-key-not-real";
  process.env.STRIPE_PRODUCT_ID = "agentsafe_mac_lifetime";
  let sent;
  globalThis.fetch = async (url, init) => {
    sent = new URLSearchParams(String(init.body));
    return { ok: true, status: 200, json: async () => ({ url: "https://checkout.stripe.test/c/pay" }) };
  };
  try {
    await createCheckout({ priceCents: 199, origin: "https://safeagent.live" });
    assert.equal(sent.get("line_items[0][price_data][unit_amount]"), "199");
    assert.equal(sent.get("line_items[0][price_data][currency]"), "usd");
    assert.equal(sent.get("line_items[0][price_data][product]"), "agentsafe_mac_lifetime");
    assert.equal(sent.get("line_items[0][price_data][tax_behavior]"), "inclusive", "the page says $1.99, so the buyer pays $1.99");
    assert.equal(sent.get("automatic_tax[enabled]"), "true");
    assert.equal(sent.get("metadata[sku]"), SKU);
    assert.equal(sent.get("success_url"), "https://safeagent.live/thanks?session_id={CHECKOUT_SESSION_ID}");
  } finally {
    globalThis.fetch = original;
    for (const [name, value] of [["STRIPE_SECRET_KEY", saved.key], ["STRIPE_PRODUCT_ID", saved.product]]) {
      if (value === undefined) delete process.env[name]; else process.env[name] = value;
    }
  }
});

test("sales stay closed until there is both a payment key and something to download", () => {
  const saved = { key: process.env.STRIPE_SECRET_KEY, url: process.env.DOWNLOAD_URL };
  try {
    delete process.env.STRIPE_SECRET_KEY; delete process.env.DOWNLOAD_URL;
    assert.equal(salesAreOpen(), false);
    process.env.STRIPE_SECRET_KEY = "test-key-not-real";
    assert.equal(salesAreOpen(), false, "nobody should pay for an app they cannot download yet");
    process.env.DOWNLOAD_URL = "https://example.org/AgentSafe.dmg";
    assert.equal(salesAreOpen(), true);
  } finally {
    for (const [name, value] of [["STRIPE_SECRET_KEY", saved.key], ["DOWNLOAD_URL", saved.url]]) {
      if (value === undefined) delete process.env[name]; else process.env[name] = value;
    }
  }
});
