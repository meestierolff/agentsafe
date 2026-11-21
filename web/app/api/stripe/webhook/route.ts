import { revalidatePath } from "next/cache";
import { isAgentSafeSale, verifyWebhook } from "../../../../lib/stripe.mjs";

// Stripe calls this after a checkout completes. Its one job is to refresh the home page,
// so the price ladder and the "sold" counter move the moment a sale lands instead of up
// to a minute later. Licences do not depend on it: a buyer's key is derived from their
// paid session when they open their thank-you link.
export async function POST(request: Request) {
  const body = await request.text();
  const event = verifyWebhook(body, request.headers.get("stripe-signature"), process.env.STRIPE_WEBHOOK_SECRET);
  if (!event) return new Response("Signature check failed.", { status: 400 });

  // The Stripe account also sells other products, and their events arrive here too.
  // Acknowledge them and do nothing, so Stripe does not keep retrying.
  if (isAgentSafeSale(event)) revalidatePath("/");
  return Response.json({ received: true });
}
