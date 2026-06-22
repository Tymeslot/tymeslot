defmodule TymeslotWeb.Themes.Shared.Components.AwaitingPayment do
  @moduledoc """
  Shared in-iframe "complete your payment in the new tab" view for paid
  bookings submitted from inside an embedded booker.

  Stripe Checkout cannot render inside an iframe, so the booker pushes a
  `payment_redirect_open_tab` event to the `PaymentRedirectOpenTab` JS
  hook — which calls `window.open(url, '_blank')` — and transitions the
  LiveView to the `:awaiting_payment` state. The iframe stays on this
  view until the webhook broadcasts `:paid` (→ confirmation) or
  `:expired` (→ booking form).

  The container uses inline neutral styling so themes can render it
  without a per-theme variant; the user spends only seconds here before
  the PubSub flip.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  attr :checkout_url, :string, required: true
  attr :class, :string, default: nil

  @spec awaiting_payment(map()) :: Phoenix.LiveView.Rendered.t()
  def awaiting_payment(assigns) do
    ~H"""
    <div
      class={["awaiting-payment-container", @class]}
      data-testid="awaiting-payment"
      id="awaiting-payment"
      phx-hook="PaymentRedirectOpenTab"
    >
      <div class="awaiting-payment-card">
        <div class="awaiting-payment-icon" aria-hidden="true">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              d="M14 5l7 7m0 0l-7 7m7-7H3"
            />
          </svg>
        </div>
        <h1 class="awaiting-payment-heading">
          {dgettext("booking", "Complete your payment in the new tab")}
        </h1>
        <p class="awaiting-payment-message">
          {dgettext("booking", 
            "We opened Stripe Checkout in a new browser tab. Once your payment is confirmed, this page updates automatically."
          )}
        </p>
        <p class="awaiting-payment-fallback">
          {dgettext("booking", "Did the new tab not open?")}
          <a
            href={@checkout_url}
            target="_blank"
            rel="noopener noreferrer"
            data-testid="awaiting-payment-fallback-link"
          >
            {dgettext("booking", "Open Stripe Checkout")}
          </a>
        </p>
      </div>
    </div>
    """
  end
end
