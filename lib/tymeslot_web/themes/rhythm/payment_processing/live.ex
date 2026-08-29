defmodule TymeslotWeb.Themes.Rhythm.PaymentProcessingLive do
  @moduledoc """
  Rhythm theme return page after a successful Stripe Checkout redirect.

  Subscribes to `meeting_payment:<id>` PubSub and flips to the confirmed
  view when the webhook handler broadcasts `:paid`. The webhook is the
  source of truth; this page never mutates state.

  Paid does not always mean confirmed: a meeting type can be both paid and
  approval-gated, in which case the webhook moves the meeting to
  `"awaiting_approval"` rather than `"confirmed"` (`CheckoutSessionCompleted.
  approval_status/2`). `handle_info(:paid, _)` delegates to
  `PaymentReturn.refresh_after_paid/1`, which re-fetches the meeting, not
  just the payment, so this page reads that status rather than assuming a
  successful payment finished the booking.
  """

  use TymeslotWeb, :live_view
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Meetings.MeetingState
  alias TymeslotWeb.Themes.Shared.Components.ApprovalNotice
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers
  alias TymeslotWeb.Themes.Shared.PaymentReturn

  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    PaymentReturn.mount_payment_processing(params, socket, "rhythm")
  end

  @impl Phoenix.LiveView
  def handle_info(:paid, socket) do
    {:noreply, PaymentReturn.refresh_after_paid(socket)}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="rhythm-theme-wrapper theme-2" data-testid="rhythm-payment-processing">
      <div class="payment-page-layout">
        <div class="payment-page-inner">
          <div class="payment-page-card">
            <div class="payment-page-card-body">
              <%= cond do %>
                <% @loading || @payment.status != "paid" -> %>
                  <h1 class="payment-page-heading">
                    {dgettext("booking", "Confirming your payment…")}
                  </h1>
                  <p class="payment-page-body">
                    {dgettext("booking", "Please wait while we confirm your booking.")}
                  </p>
                <% MeetingState.awaiting_approval?(@meeting) -> %>
                  <h1 class="payment-page-heading">
                    {dgettext("booking", "Payment received")}
                  </h1>
                  <p class="payment-page-body">
                    {dgettext(
                      "booking",
                      "Thanks, your payment went through. Your booking is not confirmed yet though:"
                    )}
                  </p>
                  <ApprovalNotice.block
                    organizer_name={@meeting.organizer_name}
                    stage={:after}
                    class="mt-4"
                  />
                <% true -> %>
                  <h1 class="payment-page-heading">
                    {dgettext("booking", "Booking confirmed")}
                  </h1>
                  <p class="payment-page-body">
                    {dgettext("booking", "Thank you, your booking is confirmed for %{date}.",
                      date:
                        LocalizationHelpers.format_meeting_datetime(
                          @meeting.start_time,
                          @meeting.attendee_timezone
                        )
                    )}
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
