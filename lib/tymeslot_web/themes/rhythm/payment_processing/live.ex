defmodule TymeslotWeb.Themes.Rhythm.PaymentProcessingLive do
  @moduledoc """
  Rhythm theme return page after a successful Stripe Checkout redirect.

  Subscribes to `meeting_payment:<id>` PubSub and flips to the confirmed
  view when the webhook handler broadcasts `:paid`. The webhook is the
  source of truth; this page never mutates state.
  """

  use TymeslotWeb, :live_view
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.MeetingPayments
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers
  alias TymeslotWeb.Themes.Shared.PaymentReturn

  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    PaymentReturn.mount_payment_processing(params, socket, "rhythm")
  end

  @impl Phoenix.LiveView
  def handle_info(:paid, socket) do
    payment = MeetingPayments.payment_for_meeting(socket.assigns.meeting.id)
    {:noreply, assign(socket, :payment, payment)}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="rhythm-theme-wrapper theme-2" data-testid="rhythm-payment-processing">
      <div class="payment-page-layout">
        <div class="payment-page-inner">
          <div class="payment-page-card">
            <div class="payment-page-card-body">
              <%= if !@loading && @payment.status == "paid" do %>
                <h1 class="payment-page-heading">
                  {gettext("Booking confirmed")}
                </h1>
                <p class="payment-page-body">
                  {gettext("Thank you, your booking is confirmed for %{date}.",
                    date:
                      LocalizationHelpers.format_meeting_datetime(
                        @meeting.start_time,
                        @meeting.attendee_timezone
                      )
                  )}
                </p>
              <% else %>
                <h1 class="payment-page-heading">
                  {gettext("Confirming your payment…")}
                </h1>
                <p class="payment-page-body">
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
end
