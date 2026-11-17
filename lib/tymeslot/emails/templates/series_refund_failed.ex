defmodule Tymeslot.Emails.Templates.SeriesRefundFailed do
  @moduledoc """
  Host-facing email sent when the refund of a series payment, scheduled when
  the host cancelled the series' remaining sessions
  (`Tymeslot.MeetingPayments.Workers.SeriesHostRefund`), could not be made,
  in the host's own language. The sessions stay cancelled; the money is
  still with the host, who refunds it by hand.

  Built from a normalised `RefundContext` struct, as the dispute alert is
  (`Tymeslot.Emails.Templates.ChargeDisputeOpened`).
  """

  import Swoosh.Email

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
    Normalised data for the failed series refund email. `host_user_id` picks
    the language it is written in; `reason` is why the refund was refused,
    or nil when it failed for a reason a retry could not get past.
    """

    @enforce_keys [:host_email, :amount_cents, :currency]
    defstruct [
      :host_email,
      :host_name,
      :host_user_id,
      :amount_cents,
      :currency,
      :attendee_name,
      :attendee_email,
      :meeting_title,
      :reason
    ]

    @type t :: %__MODULE__{
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

      MjmlEmail.base_email()
      |> to(recipient(context.host_name, context.host_email))
      |> subject(dgettext("emails_payments", "Series refund not made: %{amount}", amount: amount))
      |> html_body(html(host, amount, context.reason, details, payments_url))
      |> text_body(text(host, amount, context.reason, details, payments_url))
    end)
  end

  defp html(host, amount, reason, details, payments_url) do
    mjml_content = """
    #{Text.centered_html(Greeting.html(host), padding: "8px 0 4px 0", font_size: "16px")}

    #{Text.centered_text(intro(amount), padding: "0 0 8px 0")}
    #{Text.centered_text(why(reason), padding: "0 0 16px 0")}

    #{Cards.details_card(Sanitise.sanitize_for_email(dgettext("emails_payments", "Refund details")), Cards.facts_html(details))}

    #{Text.section_title(dgettext("emails_payments", "What to do"))}
    #{Text.centered_text(next_steps(), padding: "0 0 14px 0")}
    #{Buttons.action_button(@intent, dgettext("emails_payments", "Open payments"), payments_url, full_width: true)}
    """

    # A platform-to-host operational alert, as the dispute alert is.
    TemplateHelper.compile_system_template(
      mjml_content,
      dgettext("emails_payments", "Series refund not made"),
      dgettext("emails_payments", "A refund for a cancelled series could not be made."),
      intent: @intent,
      eyebrow: dgettext("emails_payments", "Action required"),
      stage_title: dgettext("emails_payments", "The refund was not made"),
      stage_subtitle:
        dgettext("emails_payments", "%{amount} is still to be refunded", amount: amount)
    )
  end

  defp text(host, amount, reason, details, payments_url) do
    Enum.join(
      [
        dgettext("emails_payments", "SERIES REFUND NOT MADE"),
        "",
        Greeting.text(host),
        "",
        intro(amount),
        why(reason),
        "",
        dgettext("emails_payments", "REFUND DETAILS:"),
        Enum.map_join(details, "\n", fn {label, value} -> "#{label} #{value}" end),
        "",
        dgettext("emails_payments", "WHAT TO DO:"),
        next_steps(),
        payments_url
      ],
      "\n"
    )
  end

  defp recipient(name, email) when is_binary(name) and name != "", do: {name, email}
  defp recipient(_name, email), do: email

  defp intro(amount),
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

  defp next_steps,
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
        {dgettext("emails_payments", "Meeting:"), context.meeting_title}
      ],
      fn {_label, value} -> is_nil(value) end
    )
  end
end
