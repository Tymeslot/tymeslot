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
  alias TymeslotWeb.Helpers.LocaleFormat
  alias TymeslotWeb.Themes.Shared.Components.ApprovalNotice
  alias TymeslotWeb.Themes.Shared.Components.MeetingPrice
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers
  alias TymeslotWeb.Themes.Shared.PaymentReturn

  attr :loading, :boolean, required: true
  attr :payment, :any, required: true
  attr :meeting, :any, required: true
  attr :rebook_path, :string, default: nil

  attr :series_count, :integer,
    default: nil,
    doc: "how many sessions the meeting's series has, nil for a meeting of its own"

  attr :outcome, :atom,
    default: nil,
    doc:
      "the outcome to show, when the page decides it (a seat's, `PaymentReturn.Seat.outcome/3`); nil asks `PaymentReturn.outcome/3`"

  attr :seat_hold, :any,
    default: nil,
    doc: "the seat hold a group seat's page is about, nil for a meeting's"

  @doc """
  The processing page body: one of the seven outcomes of
  `PaymentReturn.outcome/3`, or the `outcome` the page passes.
  """
  @spec processing_body(map()) :: Phoenix.LiveView.Rendered.t()
  def processing_body(assigns) do
    assigns = assign(assigns, :shown, PaymentReturn.page_outcome(assigns))

    # One live region, so a screen reader hears the outcome replace the
    # wait without moving focus.
    ~H"""
    <div role="status" aria-live="polite" data-testid="payment-processing-status">
      <%= case @shown do %>
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
          <.paid_line payment={@payment} />
          <p :if={PaymentReturn.approval_deadline_text(@meeting)} class="payment-page-body">
            <%= if Approval.refunds_on_release?(@meeting) do %>
              <.with_date
                date={PaymentReturn.approval_deadline_text(@meeting)}
                article={:none}
                text={
                  dgettext(
                    "booking_payments",
                    "If there's no answer by %{by_deadline}, the request lapses and you're refunded automatically.",
                    by_deadline: date_marker()
                  )
                }
              />
            <% else %>
              <.with_date
                date={PaymentReturn.approval_deadline_text(@meeting)}
                article={:none}
                text={
                  dgettext(
                    "booking_payments",
                    "If there's no answer by %{by_deadline}, the request lapses.",
                    by_deadline: date_marker()
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
          <.expired
            seat_hold={@seat_hold}
            meeting={@meeting}
            payment={@payment}
            rebook_path={@rebook_path}
          />
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
              article={:none}
              text={confirmed_text(@series_count)}
            />
          </p>
          <.paid_line payment={@payment} />
      <% end %>
    </div>
    """
  end

  attr :seat_hold, :any, required: true
  attr :meeting, :any, required: true
  attr :payment, :any, required: true
  attr :rebook_path, :string, default: nil

  # A request the organiser did not answer in time, or, on a seat's page, a
  # seat hold released before it became a seat: its checkout lapsed or was
  # left, or its payment came once the hold had gone and found the session
  # full, and is refunded.
  defp expired(%{seat_hold: nil} = assigns) do
    ~H"""
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
    """
  end

  defp expired(assigns) do
    ~H"""
    <h1 class="payment-page-heading">
      {dngettext(
        "booking_payments",
        "Your seat was released",
        "Your seats were released",
        @seat_hold.seats
      )}
    </h1>
    <%= if match?(%{paid_at: %DateTime{}}, @payment) do %>
      <p class="payment-page-body">
        {dngettext(
          "booking_payments",
          "Your payment arrived after the seat held for you was released, and the session had no room left. Your payment is being refunded.",
          "Your payment arrived after the seats held for you were released, and the session had no room left. Your payment is being refunded.",
          @seat_hold.seats
        )}
      </p>
    <% else %>
      <p class="payment-page-body">
        {dngettext(
          "booking_payments",
          "The payment wasn't completed in time, so the seat held for you was released. You can return and book again.",
          "The payment wasn't completed in time, so the seats held for you were released. You can return and book again.",
          @seat_hold.seats
        )}
      </p>
      <a :if={@rebook_path} href={@rebook_path} class="payment-page-link">
        {dgettext("booking_payments", "Return to booking")}
      </a>
    <% end %>
    """
  end

  attr :rebook_path, :string, default: nil

  attr :invitation_held, :boolean,
    default: false,
    doc: "the booking still holds the invitation it was made through (`PaymentReturn.rebook/3`)"

  attr :invitation_withheld, :boolean,
    default: false,
    doc:
      "the booking was made through an invitation, but the visitor did not prove they are its guest, so the page offers no link with its token (`PaymentReturn.rebook/3`)"

  @doc """
  The cancelled page body: the booking is not confirmed, with a way back, or,
  while the booking still holds the invitation it was made through, when
  there will be one, or, for a visitor not shown the invitation, where to
  find it.
  """
  @spec cancelled_body(map()) :: Phoenix.LiveView.Rendered.t()
  def cancelled_body(assigns) do
    ~H"""
    <h1 class="payment-page-heading">
      {dgettext("booking_payments", "Payment cancelled")}
    </h1>
    <p :if={@invitation_held} class="payment-page-body" data-testid="payment-invitation-held">
      {dgettext(
        "booking_payments",
        "Your booking is not confirmed. Your invitation stays reserved for it until the unfinished checkout expires, and a link to book again will appear here as soon as it does."
      )}
    </p>
    <p
      :if={@invitation_withheld}
      class="payment-page-body"
      data-testid="payment-invitation-withheld"
    >
      {dgettext(
        "booking_payments",
        "Your booking is not confirmed. To try again, open the invitation link you were sent."
      )}
    </p>
    <p :if={!@invitation_held and !@invitation_withheld} class="payment-page-body">
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

  # A series is paid and confirmed whole; the date is its first session's.
  defp confirmed_text(count) when is_integer(count) and count > 1 do
    dngettext(
      "booking_payments",
      "Thank you, your %{count} session is confirmed, the first on %{on_date}.",
      "Thank you, your %{count} sessions are confirmed, the first on %{on_date}.",
      count,
      on_date: date_marker()
    )
  end

  defp confirmed_text(_count) do
    dgettext("booking_payments", "Thank you, your booking is confirmed for %{for_date}.",
      for_date: date_marker()
    )
  end

  attr :payment, :any, required: true

  # What the booker paid, once the payment has gone through: the amount the
  # payment row took, in the guest's locale. Nothing for a payment without an
  # amount.
  defp paid_line(assigns) do
    assigns =
      assign(
        assigns,
        :amount,
        MeetingPrice.paid_price(assigns.payment, Gettext.get_locale(TymeslotWeb.Gettext))
      )

    ~H"""
    <p :if={@amount} class="payment-page-body" data-testid="payment-paid-amount">
      <.with_date
        date={@amount}
        text={dgettext("booking_payments", "Paid: %{amount}", amount: date_marker())}
      />
    </p>
    """
  end

  # A sentence's date, time or amount is drawn in its own `payment-page-date`
  # span, which a theme can keep on one line: the message is translated with
  # a marker in the placeholder's place, then split around it. A translation
  # that dropped the placeholder is shown as it is.
  @date_marker "\uE000"

  defp date_marker, do: @date_marker

  attr :text, :string, required: true
  attr :date, :string, required: true

  attr :article, :atom,
    default: nil,
    doc:
      "the preposition the message puts before a date (`LocaleFormat.with_article/3`), whose article then leads the date inside its span; nil for an amount"

  defp with_date(assigns) do
    assigns =
      assign(assigns,
        parts: String.split(assigns.text, @date_marker, parts: 2),
        date: date_with_article(assigns.date, assigns.article)
      )

    ~H"""
    <%= case @parts do %>
      <% [before, rest] -> %>
        {before}<span class="payment-page-date">{@date}</span>{rest}
      <% [text] -> %>
        {text}
    <% end %>
    """
  end

  defp date_with_article(date, nil), do: date
  defp date_with_article("", _preposition), do: ""

  defp date_with_article(date, preposition),
    do: LocaleFormat.with_article(date, preposition, Gettext.get_locale(TymeslotWeb.Gettext))
end
