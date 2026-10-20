defmodule TymeslotWeb.Themes.Shared.PaymentReturnComponents do
  @moduledoc """
  Shared, theme-neutral bodies of the payment return pages.

  Every theme draws the same content on the two pages Stripe Checkout returns
  to; only the shell around it differs. A theme's `Payment.Processing` and
  `Payment.Cancelled` modules wrap these components. The `payment-page-*`
  classes are styled once for every theme, in
  `assets/css/scheduling/shared/components/payment-pages.css`, and each theme
  sets their look through the `--payment-*` tokens in its `variables.css`.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Meetings.Approval
  alias TymeslotWeb.Themes.Shared.Components.ApprovalNotice
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers
  alias TymeslotWeb.Themes.Shared.PaymentReturn

  attr :loading, :boolean, required: true
  attr :payment, :any, required: true
  attr :meeting, :any, required: true
  attr :rebook_path, :string, default: nil

  @doc """
  The processing page body: one of the seven outcomes of
  `PaymentReturn.outcome/3`.
  """
  @spec processing_body(map()) :: Phoenix.LiveView.Rendered.t()
  def processing_body(assigns) do
    ~H"""
    <%= case PaymentReturn.outcome(@loading, @payment, @meeting) do %>
      <% :failed -> %>
        <h1 class="payment-page-heading">
          {dgettext("booking_payments", "Payment not completed")}
        </h1>
        <p class="payment-page-body">
          {dgettext(
            "booking_payments",
            "Your booking is not confirmed. You can return and try again at any time."
          )}
        </p>
        <a :if={@rebook_path} href={@rebook_path} class="payment-page-link">
          {dgettext("booking_payments", "Return to booking")}
        </a>
      <% :cancelled -> %>
        <h1 class="payment-page-heading">
          {dgettext("booking_payments", "Booking cancelled")}
        </h1>
        <p class="payment-page-body">
          {dgettext(
            "booking_payments",
            "This booking has been cancelled, so it won't be going ahead."
          )}
        </p>
      <% :loading -> %>
        <h1 class="payment-page-heading">
          {dgettext("booking_payments", "Confirming your payment…")}
        </h1>
        <p class="payment-page-body">
          {dgettext("booking_payments", "Please wait while we confirm your booking.")}
        </p>
      <% :awaiting_approval -> %>
        <h1 class="payment-page-heading">
          {dgettext("booking_payments", "Payment received")}
        </h1>
        <p class="payment-page-body">
          {dgettext(
            "booking_payments",
            "Thanks, your payment went through. Your booking is not confirmed yet though:"
          )}
        </p>
        <ApprovalNotice.block
          organizer_name={@meeting.organizer_name}
          stage={:after}
          class="mt-4"
        />
        <p :if={PaymentReturn.approval_deadline_text(@meeting)} class="payment-page-body">
          <%= if Approval.refunds_on_release?(@meeting) do %>
            <.with_date
              date={PaymentReturn.approval_deadline_text(@meeting)}
              text={
                dgettext(
                  "booking_payments",
                  "If there's no answer by %{deadline}, the request lapses and you're refunded automatically.",
                  deadline: date_marker()
                )
              }
            />
          <% else %>
            <.with_date
              date={PaymentReturn.approval_deadline_text(@meeting)}
              text={
                dgettext(
                  "booking_payments",
                  "If there's no answer by %{deadline}, the request lapses.",
                  deadline: date_marker()
                )
              }
            />
          <% end %>
        </p>
      <% :declined -> %>
        <h1 class="payment-page-heading">
          {dgettext("booking_payments", "Booking not accepted")}
        </h1>
        <p class="payment-page-body">
          <%= if Approval.refunds_on_release?(@meeting) do %>
            {dgettext(
              "booking_payments",
              "This booking wasn't accepted, so it won't be going ahead. Your payment is being refunded."
            )}
          <% else %>
            {dgettext(
              "booking_payments",
              "This booking wasn't accepted, so it won't be going ahead."
            )}
          <% end %>
        </p>
      <% :expired -> %>
        <h1 class="payment-page-heading">
          {dgettext("booking_payments", "Booking request expired")}
        </h1>
        <p class="payment-page-body">
          <%= if Approval.refunds_on_release?(@meeting) do %>
            {dgettext(
              "booking_payments",
              "Nobody responded to this request in time, so it has lapsed. Your payment is being refunded."
            )}
          <% else %>
            {dgettext(
              "booking_payments",
              "Nobody responded to this request in time, so it has lapsed."
            )}
          <% end %>
        </p>
      <% :confirmed -> %>
        <h1 class="payment-page-heading">
          {dgettext("booking_payments", "Booking confirmed")}
        </h1>
        <p class="payment-page-body">
          <.with_date
            date={
              LocalizationHelpers.format_meeting_datetime(
                @meeting.start_time,
                @meeting.attendee_timezone
              )
            }
            text={
              dgettext("booking_payments", "Thank you, your booking is confirmed for %{date}.",
                date: date_marker()
              )
            }
          />
        </p>
    <% end %>
    """
  end

  attr :rebook_path, :string, default: nil

  @doc "The cancelled page body: the booking is not confirmed, with a way back."
  @spec cancelled_body(map()) :: Phoenix.LiveView.Rendered.t()
  def cancelled_body(assigns) do
    ~H"""
    <h1 class="payment-page-heading">
      {dgettext("booking_payments", "Payment cancelled")}
    </h1>
    <p class="payment-page-body">
      {dgettext(
        "booking_payments",
        "Your booking is not confirmed. You can return and try again at any time."
      )}
    </p>
    <a :if={@rebook_path} href={@rebook_path} class="payment-page-link">
      {dgettext("booking_payments", "Return to booking")}
    </a>
    """
  end

  # A sentence's date or time is drawn in its own `payment-page-date` span,
  # which a theme can keep on one line: the message is translated with a
  # marker in the placeholder's place, then split around it. A translation
  # that dropped the placeholder is shown as it is.
  @date_marker "\uE000"

  defp date_marker, do: @date_marker

  attr :text, :string, required: true
  attr :date, :string, required: true

  defp with_date(assigns) do
    assigns = assign(assigns, :parts, String.split(assigns.text, @date_marker, parts: 2))

    ~H"""
    <%= case @parts do %>
      <% [before, rest] -> %>
        {before}<span class="payment-page-date">{@date}</span>{rest}
      <% [text] -> %>
        {text}
    <% end %>
    """
  end
end
