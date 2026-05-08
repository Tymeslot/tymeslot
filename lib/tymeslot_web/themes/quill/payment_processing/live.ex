defmodule TymeslotWeb.Themes.Quill.PaymentProcessingLive do
  @moduledoc """
  Quill theme return page after a successful Stripe Checkout redirect.

  The attendee lands here while the webhook is still in flight; this
  LiveView subscribes to PubSub and flips to the confirmed view as soon
  as `CheckoutSessionCompleted` broadcasts `:paid`. The webhook — not
  this page — is the source of truth for confirming the meeting; this
  page never mutates state.
  """

  use TymeslotWeb, :live_view
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias TymeslotWeb.Themes.Shared.PaymentReturn

  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    PaymentReturn.mount_payment_processing(params, socket, "quill")
  end

  @impl Phoenix.LiveView
  def handle_info(:paid, socket) do
    payment = BookingPaymentQueries.by_meeting_id(socket.assigns.meeting.id)
    {:noreply, assign(socket, :payment, payment)}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="quill-theme-wrapper theme-1" data-testid="quill-payment-processing">
      <div class="main-gradient theme-grid min-h-screen flex items-center justify-center px-4 py-8">
        <div class="w-full max-w-2xl">
          <div
            class="glass-morphism-card"
            style="background: rgba(255,255,255,0.08); border: 1px solid rgba(255,255,255,0.15); border-radius: 1rem;"
          >
            <div class="p-8 text-center">
              <%= if @payment.status == "paid" do %>
                <h1 class="text-3xl font-bold mb-3" style="color: white;">
                  {gettext("Booking confirmed")}
                </h1>
                <p class="text-lg" style="color: rgba(255,255,255,0.9);">
                  {gettext("Thank you, your booking is confirmed for %{date}.",
                    date: format_dt(@meeting.start_time)
                  )}
                </p>
              <% else %>
                <h1 class="text-3xl font-bold mb-3" style="color: white;">
                  {gettext("Confirming your payment…")}
                </h1>
                <p class="text-lg" style="color: rgba(255,255,255,0.9);">
                  {gettext("Please wait while we confirm your booking.")}
                </p>
              <% end %>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp format_dt(dt), do: Calendar.strftime(dt, "%-d %B %Y at %H:%M")
end
