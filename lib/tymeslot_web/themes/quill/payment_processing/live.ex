defmodule TymeslotWeb.Themes.Quill.PaymentProcessingLive do
  @moduledoc """
  Quill theme return page after a successful Stripe Checkout redirect.

  The attendee lands here while the webhook is still in flight; this
  LiveView subscribes to PubSub and flips to the confirmed view as soon
  as `CheckoutSessionCompleted` broadcasts `:paid`. The webhook — not
  this page — is the source of truth for confirming the meeting; this
  page never mutates state.

  Paid does not always mean confirmed: a meeting type can be both paid and
  approval-gated, in which case the webhook moves the meeting to
  `"awaiting_approval"` rather than `"confirmed"`
  (`CheckoutSessionCompleted.post_payment_status/1`).
  `handle_info(:paid, _)` delegates to `PaymentReturn.refresh_after_paid/1`,
  which re-fetches the meeting, not just the payment, so this page reads
  that status rather than assuming a successful payment finished the
  booking. `PaymentReturn.outcome/3` then turns that state (and a resolved
  approval gate outcome — declined, expired) into what `render/1` shows.
  """

  use TymeslotWeb, :live_view
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.Themes.Shared.Components.ApprovalNotice
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers
  alias TymeslotWeb.Themes.Shared.PaymentReturn

  @impl Phoenix.LiveView
  def mount(params, _session, socket) do
    PaymentReturn.mount_payment_processing(params, socket, "quill")
  end

  @impl Phoenix.LiveView
  def handle_info(:paid, socket) do
    {:noreply, PaymentReturn.refresh_after_paid(socket)}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="quill-theme-wrapper theme-1" data-testid="quill-payment-processing">
      <div class="main-gradient theme-grid payment-page-layout">
        <div class="payment-page-inner">
          <div class="payment-page-card">
            <div class="payment-page-card-body">
              <%= case PaymentReturn.outcome(@loading, @payment, @meeting) do %>
                <% :loading -> %>
                  <h1 class="payment-page-heading">
                    {dgettext("booking", "Confirming your payment…")}
                  </h1>
                  <p class="payment-page-body">
                    {dgettext("booking", "Please wait while we confirm your booking.")}
                  </p>
                <% :awaiting_approval -> %>
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
                  <p :if={PaymentReturn.approval_deadline_text(@meeting)} class="payment-page-body">
                    {dgettext(
                      "booking",
                      "If there's no answer by %{deadline}, the request lapses and you're refunded automatically.",
                      deadline: PaymentReturn.approval_deadline_text(@meeting)
                    )}
                  </p>
                <% :declined -> %>
                  <h1 class="payment-page-heading">
                    {dgettext("booking", "Booking not accepted")}
                  </h1>
                  <p class="payment-page-body">
                    {dgettext(
                      "booking",
                      "This booking wasn't accepted, so it won't be going ahead. Your payment is being refunded."
                    )}
                  </p>
                <% :expired -> %>
                  <h1 class="payment-page-heading">
                    {dgettext("booking", "Booking request expired")}
                  </h1>
                  <p class="payment-page-body">
                    {dgettext(
                      "booking",
                      "Nobody responded to this request in time, so it has lapsed. Your payment is being refunded."
                    )}
                  </p>
                <% :confirmed -> %>
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
