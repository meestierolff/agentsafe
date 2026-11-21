import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { signLicense, verifyLicense, publicKeyFromSeed } from "./license.mjs";

// The same vector the Mac app's tests check. If this passes here and there, a licence
// signed by the website is accepted by the app.
const vector = JSON.parse(readFileSync(new URL("../../shared/license-test-vector.json", import.meta.url), "utf8"));
const seed = Buffer.from(vector.seedHex, "hex").toString("base64");

test("signing reproduces the shared test vector exactly", () => {
  assert.equal(signLicense(vector.payload, seed), vector.license);
});

test("the public key derived from the seed is the one in the vector", () => {
  assert.equal(publicKeyFromSeed(seed), vector.publicKeyBase64);
});

test("a signed licence verifies and returns its payload", () => {
  assert.deepEqual(verifyLicense(vector.license, vector.publicKeyBase64), vector.payload);
});

test("a tampered licence is rejected", () => {
  const [prefix, , signature] = vector.license.split(".");
  const forged = Buffer.from(JSON.stringify({ ...vector.payload, id: "lic_free" })).toString("base64url");
  assert.equal(verifyLicense(`${prefix}.${forged}.${signature}`, vector.publicKeyBase64), null);
  assert.equal(verifyLicense("not a licence", vector.publicKeyBase64), null);
});

test("signing without a key fails loudly instead of issuing something unsigned", () => {
  assert.throws(() => signLicense(vector.payload, ""), /signing key/i);
  assert.throws(() => signLicense(vector.payload, "c2hvcnQ="), /signing key/i);
});
