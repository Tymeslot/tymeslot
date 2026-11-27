/**
 * Phoenix LiveView hook that hands a confirmed booking to the page embedding
 * the booker.
 *
 * When an embedded booking reaches its confirmation, the LiveView pushes
 * `booking_success` with `{ redirect_url, data }`: the host's redirect URL
 * (query params already applied, or null) and the booking details for the
 * host's `onSuccess(data)` callback. The hook posts
 * `{ type: "tymeslot-booking-success", data, redirectUrl }` to the parent;
 * embed.js answers with `tymeslot-booking-success-ack`, runs the callback and
 * does the redirect itself.
 *
 * The message can carry personal data, so it is posted only to the parent
 * origin the server vouches for: the origin signed into the embed token and
 * checked against the organiser's allowed domains (`EmbedAuthHook`), rendered
 * as `data-parent-origin` on the hook element. Without it nothing is posted.
 *
 * A frame placed without embed.js never answers. If no ack arrives within
 * ACK_TIMEOUT_MS and a redirect URL is set, the hook navigates the top window
 * itself, or, when the browser refuses that, opens the URL in a new tab.
 */
// Generous, so a parent whose main thread is busy still acks in time and the
// frame does not navigate the top window while embed.js does too.
export const ACK_TIMEOUT_MS = 1500;

function trustedOrigin(el) {
  const raw = el.dataset.parentOrigin;
  if (!raw) return null;
  try {
    const url = new URL(raw);
    return /^https?:$/.test(url.protocol) ? url.origin : null;
  } catch (_e) {
    return null;
  }
}

function isHttpUrl(value) {
  return typeof value === "string" && /^https?:\/\//i.test(value);
}

function navigateTop(url) {
  try {
    window.top.location.href = url;
  } catch (_e) {
    try {
      window.open(url, "_blank", "noopener");
    } catch (_e2) {
      // Pop-up blocked too; the confirmation stays on screen.
    }
  }
}

export const BookingSuccess = {
  mounted() {
    this._ackTimer = null;
    this._ackOrigin = null;

    this._onMessage = (event) => {
      if (this._ackTimer === null) return;
      if (event.source !== window.parent) return;
      if (event.origin !== this._ackOrigin) return;
      if (!event.data || event.data.type !== "tymeslot-booking-success-ack") return;
      clearTimeout(this._ackTimer);
      this._ackTimer = null;
    };
    window.addEventListener("message", this._onMessage);

    this.handleEvent("booking_success", ({ redirect_url, data }) => {
      const redirectUrl = isHttpUrl(redirect_url) ? redirect_url : null;
      const origin = trustedOrigin(this.el);
      this._ackOrigin = origin;

      if (origin) {
        try {
          window.parent.postMessage(
            { type: "tymeslot-booking-success", data: data, redirectUrl: redirectUrl },
            origin
          );
        } catch (_e) {
          // Parent gone; the fallback below still redirects.
        }
      }

      clearTimeout(this._ackTimer);
      this._ackTimer = setTimeout(() => {
        this._ackTimer = null;
        if (redirectUrl) navigateTop(redirectUrl);
      }, ACK_TIMEOUT_MS);
    });
  },

  destroyed() {
    clearTimeout(this._ackTimer);
    this._ackTimer = null;
    window.removeEventListener("message", this._onMessage);
  },
};
