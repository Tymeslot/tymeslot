defmodule Tymeslot.Emails.Templates.AppointmentCancellation.RefundNotice do
  @moduledoc """
  The host-facing "you still hold their money" block of the cancellation email.

  A cancellation does not settle a paid booking. The host may have cancelled
  and chosen not to refund, or the attendee may have cancelled, in which case
  no refund is even offered and the money stays put. Either way the host is the
  only party who can act, and nothing else tells them: the cancellation email
  is otherwise payment-blind, and the payments screen shows payment status
  without meeting status, so a settled booking and an unrefunded cancellation
  look identical there.

  Built from the `:booking_payment` snapshot `AppointmentBuilder.from_meeting/1`
  already attaches to `appointment_details`, so this needs no query of its own.
  Returns `nil` for a free booking, a fully refunded one, or a disputed one, so
  the template short-circuits on a single value.

  Attendee-facing copy is deliberately not built here. Telling a booker money
  is owed that the host may never send would be worse than saying nothing.

  Internal to `Tymeslot.Emails.Templates.AppointmentCancellation` and
  `Tymeslot.Emails.Templates.SeatUpdateForOrganizer` (a cancelled paid seat);
  nothing else should call it.
  """

  alias Tymeslot.Emails.Shared.{Formatting, Sanitise, Stack, Styles, Text}
  alias Tymeslot.MeetingPayments

  use Gettext, backend: TymeslotWeb.Gettext

  @typedoc """
  Host-facing refund notice, or `nil` when nothing is outstanding. A group
  meeting the host cancelled carries `:count` and `:choice` as well: how many
  paid seats Tymeslot can refund, and whether the cancellation refunds them
  (`:full`) or leaves the money with the host (`:none`). Its `:amount` lists
  one formatted total per currency the seats were paid in, joined by
  commas. `:outside_window` counts and totals the same way the seats paid
  more than 60 days before, which only the host's Stripe dashboard can
  refund, whatever the choice.
  """
  @type notice ::
          %{
            required(:amount) => String.t(),
            optional(:count) => non_neg_integer(),
            optional(:choice) => :full | :none,
            optional(:outside_window) => %{count: non_neg_integer(), amount: String.t()}
          }
          | nil

  @doc """
  Builds the notice from the `:booking_payment` snapshot in
  `appointment_details`, or from the `:seat_money` of a group meeting the
  host cancelled (`Tymeslot.Meetings.Cancellation.seat_refund/0`, handed on by
  `Tymeslot.Notifications.Email.GroupMeetingEmails`), or returns `nil` when
  no money is outstanding.

  Amounts are formatted here, so they follow the locale the email is
  rendered in.
  """
  @spec build(map()) :: notice()
  def build(%{
        seat_money: %{
          choice: choice,
          count: count,
          totals: totals,
          outside_window: outside_window
        }
      }) do
    %{
      choice: choice,
      count: count,
      amount: format_totals(totals),
      outside_window: %{count: outside_window.count, amount: format_totals(outside_window.totals)}
    }
  end

  def build(appointment_details) do
    payment = Map.get(appointment_details, :booking_payment)

    if MeetingPayments.refund_outstanding?(payment) do
      outstanding = MeetingPayments.refundable_remaining_cents(payment)
      %{amount: Formatting.format_currency(outstanding, payment.currency)}
    end
  end

  # Each currency's total in that currency, listed with commas rather than a
  # translated connective.
  defp format_totals(totals),
    do: Enum.map_join(totals, ", ", &Formatting.format_currency(&1.amount_cents, &1.currency))

  @doc "Renders the notice as MJML, or an empty string when there is none."
  @spec html(notice()) :: String.t()
  def html(nil), do: ""

  def html(%{choice: _choice} = seats),
    do: card(seats_title(seats), Enum.join(seats_lines(seats, true), "<br /><br />"))

  def html(%{amount: amount}) do
    card(
      dgettext("emails_booking_changes", "Refund outstanding"),
      dgettext("emails_booking_changes", "You still hold %{amount} for this booking.",
        amount: strong(amount)
      ),
      dgettext(
        "emails_booking_changes",
        "Cancelling does not refund anything on its own. Issue or decline the refund under Payments in your dashboard."
      )
    )
  end

  @doc "Renders the notice as plain text, or an empty string when there is none."
  @spec text(notice()) :: String.t()
  def text(nil), do: ""

  def text(%{choice: _choice} = seats) do
    """

    #{seats_text_title(seats)}
    #{Enum.join(seats_lines(seats, false), "\n")}
    """
  end

  def text(%{amount: amount}) do
    """

    #{dgettext("emails_booking_changes", "REFUND OUTSTANDING:")}
    #{dgettext("emails_booking_changes", "You still hold %{amount} for this booking.", amount: amount)}
    #{dgettext("emails_booking_changes", "Cancelling does not refund anything on its own. Issue or decline the refund under Payments in your dashboard.")}
    """
  end

  # Refunds are on their way only when the cancellation refunds a seat;
  # seats past the refund window alone are money the host still holds.
  defp seats_title(%{choice: :full, count: count}) when count > 0,
    do: dgettext("emails_booking_changes", "Refunds on their way")

  defp seats_title(_seats), do: dgettext("emails_booking_changes", "Refunds outstanding")

  defp seats_text_title(%{choice: :full, count: count}) when count > 0,
    do: dgettext("emails_booking_changes", "REFUNDS ON THEIR WAY:")

  defp seats_text_title(_seats), do: dgettext("emails_booking_changes", "REFUNDS OUTSTANDING:")

  # The seats Tymeslot can refund, then those past the refund window, each
  # said only when there are some.
  defp seats_lines(seats, bold?) do
    outside_window = Map.get(seats, :outside_window, %{count: 0})

    Enum.filter(
      [
        seats.count > 0 && seats_line(seats, bold?),
        outside_window.count > 0 && outside_window_line(outside_window, bold?)
      ],
      & &1
    )
  end

  defp outside_window_line(%{count: count, amount: amount}, bold?) do
    dngettext(
      "emails_booking_changes",
      "%{amount} from %{count} participant can't be refunded automatically: the payment is older than the 60-day refund window. Refund it from your Stripe dashboard.",
      "%{amount} from %{count} participants can't be refunded automatically: their payments are older than the 60-day refund window. Refund them from your Stripe dashboard.",
      count,
      amount: amount(amount, bold?),
      count: count
    )
  end

  # `bold?` marks the amount for the MJML body; the plain-text line shares the
  # translation, with the markup riding in on the placeholder.
  defp seats_line(%{choice: :full, count: count, amount: amount}, bold?) do
    dngettext(
      "emails_booking_changes",
      "%{amount} is being refunded to %{count} participant. They get an email once the refund is issued.",
      "%{amount} is being refunded to %{count} participants. Each gets an email once their refund is issued.",
      count,
      amount: amount(amount, bold?),
      count: count
    )
  end

  defp seats_line(%{choice: :none, count: count, amount: amount}, bold?) do
    dngettext(
      "emails_booking_changes",
      "You still hold %{amount} from %{count} participant. Refund it under Payments in your dashboard if you need to.",
      "You still hold %{amount} from %{count} participants. Refund them under Payments in your dashboard if you need to.",
      count,
      amount: amount(amount, bold?),
      count: count
    )
  end

  defp amount(amount, true), do: strong(amount)
  defp amount(amount, false), do: amount

  defp card(title, line, note \\ nil) do
    """
    #{Text.section_title(title)}
    #{Stack.spaced("""
      <mj-section
        background-color="#{Styles.canvas_soft()}"
        border-radius="#{Styles.card_radius()}"
        padding="20px 26px"
        css-class="mobile-card email-canvas-soft"
      >
        <mj-column>
          <mj-text
            font-size="15px"
            color="#{Styles.text_color(:primary)}"
            line-height="1.7"
            align="left"
          >
            #{line}
          </mj-text>
          #{note_block(note)}
        </mj-column>
      </mj-section>
    """)}
    """
  end

  defp note_block(nil), do: ""

  defp note_block(note) do
    """
    <mj-text
      font-size="13px"
      color="#{Styles.text_color(:muted)}"
      line-height="1.55"
      align="left"
      padding-top="12px"
    >
      #{note}
    </mj-text>
    """
  end

  # The bold markup rides in on the placeholder rather than living inside the
  # msgid, so the HTML and plain-text lines share one translation.
  defp strong(amount), do: "<strong>#{Sanitise.sanitize_for_email(amount)}</strong>"
end
