defmodule Tymeslot.Emails.Templates.RefundFailed do
  @moduledoc """
  Host-facing email sent when a refund the host decided failed for good
  (`Tymeslot.Workers.SendRefundFailed`), in the host's own language: Stripe
  declined it or never completed it. Worded for a refund of the host's own
  choosing, or for one that went with cancelling sessions of a series,
  which stay cancelled. The money is still with the host, who settles it
  from Stripe.

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
    Normalised data for the failed refund email. `host_user_id` picks the
    language it is written in; `series_cancellation?` whether the refund
    went with cancelling sessions of a series.
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
      series_cancellation?: false
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
            series_cancellation?: boolean()
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

      attendee =
        context.attendee_name || context.attendee_email ||
          dgettext("emails_payments", "the attendee")

      intro = intro(context.series_cancellation?, amount, attendee)
      details = details(context, amount)
      payments_url = UrlBuilder.build_url("/dashboard/payments")

      MjmlEmail.base_email()
      |> to(recipient(context.host_name, context.host_email))
      |> subject(subject_line(amount, attendee))
      |> html_body(html(%{name: context.host_name}, amount, intro, details, payments_url))
      |> text_body(text(%{name: context.host_name}, intro, details, payments_url))
    end)
  end

  defp html(host, amount, intro, details, payments_url) do
    mjml_content = """
    #{Text.centered_html(Greeting.html(host), padding: "8px 0 4px 0", font_size: "16px")}

    #{Text.centered_text(intro, padding: "0 0 16px 0")}

    #{Cards.details_card(Sanitise.sanitize_for_email(dgettext("emails_payments", "Refund details")), Cards.facts_html(details))}

    #{Text.section_title(dgettext("emails_payments", "What to do"))}
    #{Text.centered_text(next_steps(), padding: "0 0 14px 0")}
    #{Buttons.action_button(@intent, dgettext("emails_payments", "Open payments"), payments_url, full_width: true)}
    """

    # A platform-to-host operational alert, as the dispute alert is.
    TemplateHelper.compile_system_template(
      mjml_content,
      dgettext("emails_payments", "Refund not made"),
      dgettext("emails_payments", "Stripe declined or could not complete a refund."),
      intent: @intent,
      eyebrow: dgettext("emails_payments", "Action required"),
      stage_title: dgettext("emails_payments", "The refund was not made"),
      stage_subtitle:
        dgettext("emails_payments", "%{amount} is still to be refunded", amount: amount)
    )
  end

  defp text(host, intro, details, payments_url) do
    Enum.join(
      [
        dgettext("emails_payments", "REFUND NOT MADE"),
        "",
        Greeting.text(host),
        "",
        intro,
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

  defp subject_line(amount, attendee),
    do:
      dgettext("emails_payments", "Refund of %{amount} to %{attendee} not made",
        amount: amount,
        attendee: attendee
      )

  defp intro(true, amount, attendee),
    do:
      dgettext(
        "emails_payments",
        "You cancelled sessions of a series, but Stripe declined or could not complete the refund of %{amount} to %{attendee}. The sessions stay cancelled.",
        amount: amount,
        attendee: attendee
      )

  defp intro(false, amount, attendee),
    do:
      dgettext(
        "emails_payments",
        "Stripe declined or could not complete the refund of %{amount} to %{attendee} for their booking.",
        amount: amount,
        attendee: attendee
      )

  defp next_steps,
    do:
      dgettext(
        "emails_payments",
        "Check the payment in your Stripe dashboard. The money is still yours to return: refund the attendee from your payments in Tymeslot or from Stripe, or let them know what happens next."
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
