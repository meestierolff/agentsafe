import { NextResponse } from "next/server";
import { priceForNextSale } from "../../../lib/pricing.mjs";
import { countPaidSales, createCheckout, salesAreOpen } from "../../../lib/stripe.mjs";

// Starts a Stripe Checkout for one licence at the current ladder price.
// The price is computed here from Stripe's own sale count. The request carries no amount.
export async function POST(request: Request) {
  const origin = new URL(request.url).origin;
  if (!salesAreOpen()) return NextResponse.redirect(`${origin}/#price`, 303);
  try {
    const sold = await countPaidSales();
    const session = await createCheckout({ priceCents: priceForNextSale(sold), origin });
    return NextResponse.redirect(session.url, 303);
  } catch (error) {
    console.error("checkout failed", error);
    return NextResponse.redirect(`${origin}/#price`, 303);
  }
}
