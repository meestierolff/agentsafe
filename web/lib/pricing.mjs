// The launch price ladder: $0.99 for the first five buyers, then $1 more after every
// fifth sale, stopping at $5.99. The price is always worked out on the server from the
// number of sales Stripe reports; nothing the browser sends can change it.

export const LADDER = { startCents: 99, stepCents: 100, salesPerStep: 5, capCents: 599 };

function cleanCount(sold) {
  return Number.isFinite(sold) && sold > 0 ? Math.floor(sold) : 0;
}

/** Price in cents for whoever buys next, given how many have been sold. */
export function priceForNextSale(sold) {
  const steps = Math.floor(cleanCount(sold) / LADDER.salesPerStep);
  return Math.min(LADDER.startCents + steps * LADDER.stepCents, LADDER.capCents);
}

export function ladderState(sold) {
  const count = cleanCount(sold);
  const priceCents = priceForNextSale(count);
  const atCap = priceCents >= LADDER.capCents;
  return {
    sold: count,
    priceCents,
    leftAtThisPrice: atCap ? null : LADDER.salesPerStep - (count % LADDER.salesPerStep),
    nextPriceCents: atCap ? null : priceCents + LADDER.stepCents,
  };
}

export function formatUSD(cents) {
  return `$${(cents / 100).toFixed(2)}`;
}
