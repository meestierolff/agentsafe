// Licence keys: `AS1.<payload>.<signature>`, signed with Ed25519.
//
// The website holds the private key and signs. The Mac app ships only the public key,
// which can check a signature but cannot make one. That is why the app can tell a real
// licence from a fake one without ever going online.

import { createPrivateKey, createPublicKey, sign, verify } from "node:crypto";

const PREFIX = "AS1";
// Wraps a raw 32-byte Ed25519 seed in the PKCS#8 envelope Node expects.
const PKCS8_HEADER = Buffer.from("302e020100300506032b657004220420", "hex");
const SPKI_HEADER = Buffer.from("302a300506032b6570032100", "hex");

function privateKeyFromSeed(seedBase64) {
  const seed = Buffer.from(seedBase64 ?? "", "base64");
  if (seed.length !== 32) throw new Error("Licence signing key is missing or malformed.");
  return createPrivateKey({ key: Buffer.concat([PKCS8_HEADER, seed]), format: "der", type: "pkcs8" });
}

export function publicKeyFromSeed(seedBase64) {
  const spki = createPublicKey(privateKeyFromSeed(seedBase64)).export({ format: "der", type: "spki" });
  return spki.subarray(-32).toString("base64");
}

/** @param {{id: string, email?: string, iat: number, sku: string}} payload */
export function signLicense(payload, seedBase64) {
  const key = privateKeyFromSeed(seedBase64);
  const body = `${PREFIX}.${Buffer.from(JSON.stringify(payload)).toString("base64url")}`;
  return `${body}.${sign(null, Buffer.from(body), key).toString("base64url")}`;
}

/** Returns the payload, or null when the licence is not genuine. */
export function verifyLicense(license, publicKeyBase64) {
  const parts = String(license).replace(/\s+/g, "").split(".");
  if (parts.length !== 3 || parts[0] !== PREFIX) return null;
  try {
    const publicKey = createPublicKey({
      key: Buffer.concat([SPKI_HEADER, Buffer.from(publicKeyBase64, "base64")]),
      format: "der",
      type: "spki",
    });
    const ok = verify(null, Buffer.from(`${parts[0]}.${parts[1]}`), publicKey, Buffer.from(parts[2], "base64url"));
    return ok ? JSON.parse(Buffer.from(parts[1], "base64url").toString("utf8")) : null;
  } catch {
    return null;
  }
}
