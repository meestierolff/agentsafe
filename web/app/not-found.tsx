import type { Metadata } from "next";
import { TitleBar } from "./components/chrome";
import { SiteMenuBar } from "./components/site-menu-bar";

export const metadata: Metadata = { title: "Not found · AgentSafe", robots: { index: false } };

export default function NotFound() {
  return (
    <div className="page">
      <div className="pinstripes" aria-hidden="true" />
      <div className="page-content">
        <SiteMenuBar base="/" downloadUrl={process.env.DOWNLOAD_URL || undefined} />
        <div className="hero-wrap">
          <div className="page-backdrop" aria-hidden="true">
            <div className="aurora" />
            <div className="stars" />
          </div>
          <main className="page-window-wrap">
            <section className="window page-window" aria-labelledby="missing-title">
              <TitleBar title="Not Found" />
              <div className="page-window-body">
                <h1 id="missing-title">There is nothing at this address.</h1>
                <p>The page may have moved, or the link was cut off when it was copied.</p>
                <div className="row"><a className="btn btn-md btn-aqua" href="/">Go to AgentSafe</a></div>
              </div>
            </section>
          </main>
        </div>
      </div>
    </div>
  );
}
