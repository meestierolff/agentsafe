import test from "node:test";
import assert from "node:assert/strict";
import { ladderState, priceForNextSale, formatUSD } from "./pricing.mjs";

test("the first five buyers pay $0.99", () => {
  for (const sold of [0, 1, 4]) assert.equal(priceForNextSale(sold), 99);
});

test("the price goes up $1 after every fifth sale", () => {
  assert.equal(priceForNextSale(5), 199);
  assert.equal(priceForNextSale(9), 199);
  assert.equal(priceForNextSale(10), 299);
  assert.equal(priceForNextSale(24), 499);
});

test("the price stops at $5.99", () => {
  assert.equal(priceForNextSale(25), 599);
  assert.equal(priceForNextSale(10_000), 599);
});

test("the ladder says how many are left at this price and what comes next", () => {
  assert.deepEqual(ladderState(0), { sold: 0, priceCents: 99, leftAtThisPrice: 5, nextPriceCents: 199 });
  assert.deepEqual(ladderState(7), { sold: 7, priceCents: 199, leftAtThisPrice: 3, nextPriceCents: 299 });
  assert.deepEqual(ladderState(25), { sold: 25, priceCents: 599, leftAtThisPrice: null, nextPriceCents: null });
});

test("a nonsense count never produces a nonsense price", () => {
  for (const bad of [-3, NaN, undefined, 2.7]) assert.ok([99, 199, 299, 399, 499, 599].includes(priceForNextSale(bad)));
});

test("prices are written the way people read them", () => {
  assert.equal(formatUSD(99), "$0.99");
  assert.equal(formatUSD(599), "$5.99");
});
