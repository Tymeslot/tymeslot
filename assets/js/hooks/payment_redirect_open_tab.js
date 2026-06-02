/**
 * Phoenix LiveView hook for paid bookings inside an embedded booker.
 *
 * Stripe Checkout cannot render inside an iframe (Stripe blocks framing),
 * so when a paid booking is submitted from inside an embed the LiveView
 * pushes a `payment_redirect_open_tab` event to this hook with the
 * Checkout URL. The hook opens Stripe Checkout in a new tab while the
 * iframe stays put on a "complete in new tab" view; the LiveView is
 * subscribed to `meeting_payment:<id>` PubSub and flips to the
 * confirmation/cancelled view when the webhook lands.
 *
 * The hook is idempotent on the same URL: LiveView re-renders may invoke
 * `mounted()` again with the same checkout URL, but we don't want to
 * keep spawning new tabs.
 */
export const PaymentRedirectOpenTab = {
  mounted() {
    this._lastOpenedUrl = null;

    this.handleEvent("payment_redirect_open_tab", ({ url }) => {
      if (typeof url !== "string" || !url) return;
      if (url === this._lastOpenedUrl) return;
      this._lastOpenedUrl = url;

      try {
        // _blank, noopener, noreferrer — never share opener handle with
        // Stripe Checkout, treat the new tab as untrusted.
        window.open(url, "_blank", "noopener,noreferrer");
      } catch (_e) {
        // Pop-up blocker rejected the call — the in-iframe view already
        // shows a fallback link the user can click manually.
      }
    });
  },
};
