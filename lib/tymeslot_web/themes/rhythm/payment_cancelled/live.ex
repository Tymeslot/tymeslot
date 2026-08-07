defmodule TymeslotWeb.Themes.Rhythm.PaymentCancelledLive do
  @moduledoc """
  Rhythm theme return page after a Stripe Checkout cancel.

  Tells the attendee the booking is not confirmed and that they may
  return to the host's booking page to try again.
  """

  use TymeslotWeb, :live_view
  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView
  alias TymeslotWeb.Themes.Shared.PaymentReturn

  @impl Phoenix.LiveView
  def mount(%{"meeting_id" => meeting_id}, _session, socket) do
    if LiveView.connected?(socket) do
      case PaymentReturn.lookup_for_cancel(meeting_id, "rhythm") do
        {:ok, %{meeting: meeting, rebook_path: rebook_path}} ->
          {:ok, assign(socket, loading: false, meeting: meeting, rebook_path: rebook_path)}

        {:error, _reason} ->
          {:ok, redirect(socket, to: ~p"/")}
      end
    else
      {:ok, assign(socket, loading: true, meeting: nil, rebook_path: nil)}
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="rhythm-theme-wrapper theme-2" data-testid="rhythm-payment-cancelled">
      <div class="payment-page-layout">
        <div class="payment-page-inner">
          <div class="payment-page-card">
            <div class="payment-page-card-body">
              <h1 class="payment-page-heading">
                {dgettext("booking", "Payment cancelled")}
              </h1>
              <p class="payment-page-body">
                {dgettext(
                  "booking",
                  "Your booking is not confirmed. You can return and try again at any time."
                )}
              </p>
              <a :if={@rebook_path} href={@rebook_path} class="payment-page-link">
                {dgettext("booking", "Return to booking")}
              </a>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
