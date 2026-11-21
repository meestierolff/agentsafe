import type { Metadata } from "next";
import { signLicense } from "../../lib/license.mjs";
import { SKU, licenseIdFor, paidSession } from "../../lib/stripe.mjs";
import { CopyButton } from "../copy-button";

export const metadata: Metadata = { title: "Your AgentSafe licence", robots: { index: false } };
// The licence depends on the link's session id, so this page is never cached.
export const dynamic = "force-dynamic";

export default async function Thanks({ searchParams }: { searchParams: Promise<{ session_id?: string }> }) {
  const { session_id } = await searchParams;
  const session = await paidSession(session_id);

  // The licence is derived from the paid session, so reopening this link always shows
  // the same key. Nothing about the buyer is stored on this site.
  const license = session
    ? signLicense(
        { id: licenseIdFor(session.id), email: session.customer_details?.email ?? undefined, iat: session.created, sku: SKU },
        process.env.LICENSE_SIGNING_KEY,
      )
    : null;
  const downloadURL = process.env.DOWNLOAD_URL;

  return (
    <div className="desktop">
      <header className="menubar">
        <a className="brand" href="/">
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img src="/icon.png" alt="" width={18} height={18} />
          AgentSafe
        </a>
      </header>
      <main className="column" style={{ paddingTop: 56 }}>
        <section className="window" aria-labelledby="thanks-title">
          <div className="titlebar"><span id="thanks-title">{license ? "Your licence" : "Licence not found"}</span></div>
          <div className="pane">
            {license ? (
              <>
                <h2>Thank you. Here is your licence key.</h2>
                <p>Open AgentSafe, go to Settings, paste this key and choose Activate. It works on every Mac you own.</p>
                <textarea className="licence" readOnly defaultValue={license} aria-label="Licence key" />
                <p><CopyButton text={license} /></p>
                <p>
                  <strong>Keep this page&rsquo;s link.</strong> Opening it again shows the same key. We do not keep a
                  copy of your email, so the link is your record.
                </p>
                {downloadURL && <p><a className="gel plain" href={downloadURL}>Download AgentSafe for Mac</a></p>}
              </>
            ) : (
              <>
                <h2>We could not find a paid purchase for this link.</h2>
                <p>
                  If you just paid, wait a few seconds and reload. If the link was cut off when you copied it, open it
                  again from your browser history.
                </p>
                <p><a className="gel plain" href="/#price">Back to AgentSafe</a></p>
              </>
            )}
          </div>
        </section>
      </main>
    </div>
  );
}
