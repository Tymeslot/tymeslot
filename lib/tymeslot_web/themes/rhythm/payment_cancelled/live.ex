defmodule TymeslotWeb.Themes.Rhythm.PaymentCancelledLive do
  @moduledoc """
  Rhythm theme return page after a Stripe Checkout cancel.

  Tells the attendee the booking is not confirmed and that they may
  return to the host's booking page to try again.
  """

  use TymeslotWeb, :live_view
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Themes.Shared.PaymentReturn

  @impl Phoenix.LiveView
  def mount(%{"meeting_id" => meeting_id}, _session, socket) do
    case PaymentReturn.lookup_for_cancel(meeting_id, "rhythm") do
      {:ok, %{meeting: meeting}} ->
        {:ok, assign(socket, :meeting, meeting)}

      {:error, _reason} ->
        {:ok, redirect(socket, to: ~p"/")}
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="rhythm-theme-wrapper theme-2" data-testid="rhythm-payment-cancelled">
      <div class="rhythm-slide-container min-h-screen flex items-center justify-center px-4 py-8">
        <div
          class="w-full max-w-xl rhythm-card"
          style="background: rgba(0,0,0,0.55); border: 1px solid rgba(255,255,255,0.12); border-radius: 1rem;"
        >
          <div class="p-8 text-center">
            <h1 class="text-3xl font-bold mb-3" style="color: white;">
              {gettext("Payment cancelled")}
            </h1>
            <p class="text-lg" style="color: rgba(255,255,255,0.85);">
              {gettext(
                "Your booking is not confirmed. You can return and try again at any time."
              )}
            </p>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
