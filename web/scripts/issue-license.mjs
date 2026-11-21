// Issues a licence by hand (for yourself, a friend, or a refund-and-reissue).
//
//   node --env-file=.env.local scripts/issue-license.mjs "note or email" > licence.txt
//
// Needs LICENSE_SIGNING_KEY in the environment. Prints only the licence.

import { randomBytes } from "node:crypto";
import { signLicense } from "../lib/license.mjs";

const label = process.argv[2];
const payload = {
  id: `lic_manual_${randomBytes(6).toString("hex")}`,
  ...(label ? { email: label } : {}),
  iat: Math.floor(Date.now() / 1000),
  sku: "agentsafe-mac",
};
process.stdout.write(signLicense(payload, process.env.LICENSE_SIGNING_KEY) + "\n");
