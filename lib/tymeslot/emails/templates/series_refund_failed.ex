defmodule Tymeslot.Emails.Templates.SeriesRefundFailed do
  @moduledoc """
  Host-facing email sent when a refund the host's cancellation scheduled
  could not be made, in the host's own language: of a series payment, when
  the host cancelled the series' remaining sessions
  (`Tymeslot.MeetingPayments.Workers.SeriesHostRefund`), or of one paid
  seat, when the host cancelled a group session
  (`Tymeslot.MeetingPayments.Workers.GroupCancelRefund`, `kind:
  :group_meeting`). The sessions stay cancelled; the money is still with the
  host, who refunds it by hand.

  Built from a normalised `RefundContext` struct, as the dispute alert is
  (`Tymeslot.Emails.Templates.ChargeDisputeOpened`).
  """

  import Swoosh.Email

  alias Tymeslot.Emails.HostClock
  alias Tymeslot.Emails.RecipientLocale

  alias Tymeslot.Emails.Shared.{
    Buttons,
    Cards,
    Formatting,
    Greeting,
    MjmlEmail,
    Sanitise,
    TemplateHelper,
    Text
  }

  alias Tymeslot.Utils.UrlBuilder

  use Gettext, backend: TymeslotWeb.Gettext

  @intent :cancelled

  defmodule RefundContext do
    @moduledoc """
    Normalised data for the failed refund email. `host_user_id` picks the
    language it is written in; `reason` is why the refund was refused, or
    nil when it failed for a reason a retry could not get past. `kind` says
    what was cancelled: a series (the default) or a group session, whose
    `meeting_start` the email states.
    """

    @enforce_keys [:host_email, :amount_cents, :currency]
    defstruct [
      :meeting_start,
      :host_email,
      :host_name,
      :host_user_id,
      :amount_cents,
      :currency,
      :attendee_name,
      :attendee_email,
      :meeting_title,
      :reason,
      kind: :series
    ]

    @type t :: %__MODULE__{
            kind: :series | :group_meeting,
            meeting_start: DateTime.t() | nil,
            host_email: String.t(),
            host_name: String.t() | nil,
            host_user_id: integer() | nil,
            amount_cents: pos_integer(),
            currency: String.t(),
            attendee_name: String.t() | nil,
            attendee_email: String.t() | nil,
            meeting_title: String.t() | nil,
            reason: atom() | nil
          }
  end

  @doc """
  The failed refund alert, in the language of the host identified by
  `host_user_id` (the default locale when there is none).
  """
  @spec render(RefundContext.t()) :: Swoosh.Email.t()
  def render(%RefundContext{} = context) do
    RecipientLocale.with_user_id_locale(context.host_user_id, fn ->
      amount = Formatting.format_currency(context.amount_cents, context.currency)
      host = %{name: context.host_name}
      details = details(context, amount)
      payments_url = UrlBuilder.build_url("/dashboard/payments")
      kind = context.kind

      MjmlEmail.base_email()
      |> to(recipient(context.host_name, context.host_email))
      |> subject(subject_line(kind, amount))
      |> html_body(html(kind, host, amount, context.reason, details, payments_url))
      |> text_body(text(kind, host, amount, context.reason, details, payments_url))
    end)
  end

  defp subject_line(:group_meeting, amount),
    do: dgettext("emails_payments", "Group session refund not made: %{amount}", amount: amount)

  defp subject_line(_series, amount),
    do: dgettext("emails_payments", "Series refund not made: %{amount}", amount: amount)

  defp title(:group_meeting), do: dgettext("emails_payments", "Group session refund not made")
  defp title(_series), do: dgettext("emails_payments", "Series refund not made")

  defp preheader(:group_meeting),
    do: dgettext("emails_payments", "A refund for a cancelled group session could not be made.")

  defp preheader(_series),
    do: dgettext("emails_payments", "A refund for a cancelled series could not be made.")

  defp heading(:group_meeting), do: dgettext("emails_payments", "GROUP SESSION REFUND NOT MADE")
  defp heading(_series), do: dgettext("emails_payments", "SERIES REFUND NOT MADE")

  defp html(kind, host, amount, reason, details, payments_url) do
    mjml_content = """
    #{Text.centered_html(Greeting.html(host), padding: "8px 0 4px 0", font_size: "16px")}

    #{Text.centered_text(intro(kind, amount), padding: "0 0 8px 0")}
    #{Text.centered_text(why(reason), padding: "0 0 16px 0")}

    #{Cards.details_card(Sanitise.sanitize_for_email(dgettext("emails_payments", "Refund details")), Cards.facts_html(details))}

    #{Text.section_title(dgettext("emails_payments", "What to do"))}
    #{Text.centered_text(next_steps(kind), padding: "0 0 14px 0")}
    #{Buttons.action_button(@intent, dgettext("emails_payments", "Open payments"), payments_url, full_width: true)}
    """

    # A platform-to-host operational alert, as the dispute alert is.
    TemplateHelper.compile_system_template(
      mjml_content,
      title(kind),
      preheader(kind),
      intent: @intent,
      eyebrow: dgettext("emails_payments", "Action required"),
      stage_title: dgettext("emails_payments", "The refund was not made"),
      stage_subtitle:
        dgettext("emails_payments", "%{amount} is still to be refunded", amount: amount)
    )
  end

  defp text(kind, host, amount, reason, details, payments_url) do
    Enum.join(
      [
        heading(kind),
        "",
        Greeting.text(host),
        "",
        intro(kind, amount),
        why(reason),
        "",
        dgettext("emails_payments", "REFUND DETAILS:"),
        Enum.map_join(details, "\n", fn {label, value} -> "#{label} #{value}" end),
        "",
        dgettext("emails_payments", "WHAT TO DO:"),
        next_steps(kind),
        payments_url
      ],
      "\n"
    )
  end

  defp recipient(name, email) when is_binary(name) and name != "", do: {name, email}
  defp recipient(_name, email), do: email

  defp intro(:group_meeting, amount),
    do:
      dgettext(
        "emails_payments",
        "You cancelled a group session, but the refund of %{amount} to one of its attendees could not be made. The session stays cancelled.",
        amount: amount
      )

  defp intro(_series, amount),
    do:
      dgettext(
        "emails_payments",
        "You cancelled the remaining sessions of a series, but the refund of %{amount} to the attendee could not be made. The sessions stay cancelled.",
        amount: amount
      )

  defp why(:outside_refund_window),
    do:
      dgettext(
        "emails_payments",
        "The payment is older than the 60-day refund window."
      )

  defp why(:under_dispute),
    do: dgettext("emails_payments", "The payment is under dispute.")

  defp why(_other),
    do: dgettext("emails_payments", "Stripe did not accept the refund after several attempts.")

  defp next_steps(:group_meeting),
    do:
      dgettext(
        "emails_payments",
        "Refund the attendee from your Stripe dashboard, or let them know what happens next."
      )

  defp next_steps(_series),
    do:
      dgettext(
        "emails_payments",
        "Refund the attendee from your payments in Tymeslot or from your Stripe dashboard, or let them know what happens next."
      )

  defp details(context, amount) do
    Enum.reject(
      [
        {dgettext("emails_payments", "Amount to refund:"), amount},
        {dgettext("emails_payments", "Attendee:"), context.attendee_name},
        {dgettext("emails_payments", "Attendee email:"), context.attendee_email},
        {dgettext("emails_payments", "Meeting:"), context.meeting_title},
        {dgettext("emails_payments", "Starts:"), starts(context)}
      ],
      fn {_label, value} -> is_nil(value) end
    )
  end

  defp starts(%{meeting_start: %DateTime{} = start, host_user_id: user_id})
       when is_integer(user_id),
       do: HostClock.format_datetime(start, user_id, Gettext.get_locale(TymeslotWeb.Gettext))

  defp starts(_context), do: nil
end
