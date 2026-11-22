import type { Metadata } from "next";
import { signLicense } from "../../lib/license.mjs";
import { SKU, licenseIdFor, paidSession } from "../../lib/stripe.mjs";
import { AppIcon, TitleBar } from "../components/chrome";
import { SiteMenuBar } from "../components/site-menu-bar";
import { CopyButton } from "../copy-button";

export const metadata: Metadata = { title: "Your AgentSafe licence", robots: { index: false } };
// The licence depends on the link's session id, so this page is never cached.
export const dynamic = "force-dynamic";

export default async function Thanks({ searchParams }: { searchParams: Promise<{ session_id?: string; preview?: string }> }) {
  const { session_id, preview } = await searchParams;
  const session = await paidSession(session_id);

  // The licence is derived from the paid session, so reopening this link always shows
  // the same key. Nothing about the buyer is stored on this site.
  let license = session
    ? signLicense(
        { id: licenseIdFor(session.id), email: session.customer_details?.email ?? undefined, iat: session.created, sku: SKU },
        process.env.LICENSE_SIGNING_KEY,
      )
    : null;
  // Lets the paid view be checked locally without a purchase. Never active in production.
  if (!license && preview === "1" && process.env.NODE_ENV === "development") {
    license = "AS1.preview-only-not-a-real-licence.this-key-will-not-activate-the-app";
  }

  return <LicencePage license={license} downloadUrl={process.env.DOWNLOAD_URL || undefined} />;
}

function LicencePage({ license, downloadUrl }: { license: string | null; downloadUrl?: string }) {
  return (
    <div className="page">
      <div className="pinstripes" aria-hidden="true" />
      <div className="page-content">
        <SiteMenuBar base="/" downloadUrl={downloadUrl} />
        <div className="hero-wrap">
          <div className="page-backdrop" aria-hidden="true">
            <div className="aurora" />
            <div className="stars" />
          </div>
          <main className="page-window-wrap">
            <section className="window page-window" aria-labelledby="licence-title">
              <TitleBar title={license ? "AgentSafe Licence" : "Licence not found"} />
              <div className="page-window-body">
                {license ? (
                  <>
                    <div style={{ display: "flex", alignItems: "center", gap: 16 }}>
                      <AppIcon size={52} />
                      <h1 id="licence-title">Thank you. Here is your licence key.</h1>
                    </div>
                    <p>Open AgentSafe, go to Settings, paste this key and choose Activate. It works on every Mac you own.</p>
                    <textarea className="licence-key" readOnly defaultValue={license} aria-label="Licence key" />
                    <div className="row">
                      <CopyButton text={license} />
                      {downloadUrl && <a className="btn btn-md btn-grey" href={downloadUrl}>Download AgentSafe for Mac</a>}
                    </div>
                    <p>
                      <b>Keep this page&rsquo;s link.</b> Opening it again shows the same key. We do not keep a copy of your
                      email, so the link is your record.
                    </p>
                  </>
                ) : (
                  <>
                    <h1 id="licence-title">We could not find a paid purchase for this link.</h1>
                    <p>
                      If you just paid, wait a few seconds and reload. If the link was cut off when you copied it, open it
                      again from your browser history.
                    </p>
                    <div className="row"><a className="btn btn-md btn-grey" href="/#pricing">Back to AgentSafe</a></div>
                  </>
                )}
              </div>
            </section>
          </main>
        </div>
      </div>
    </div>
  );
}
