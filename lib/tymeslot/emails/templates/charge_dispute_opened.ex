defmodule Tymeslot.Emails.Templates.ChargeDisputeOpened do
  @moduledoc """
  Host-facing email sent when Stripe opens a dispute against a charge linked
  to one of their booking payments, in the host's own language.

  Built from a normalised `DisputeContext` struct so raw Stripe payloads do
  not leak into the template layer.
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

  use Gettext, backend: TymeslotWeb.Gettext

  @intent :cancelled
  @stripe_disputes_url "https://dashboard.stripe.com/disputes"

  defmodule DisputeContext do
    @moduledoc """
    Normalised data for the dispute email. Includes the host's contact info
    so the worker can pass everything the template needs in one struct;
    `host_user_id` picks the language the email is written in.
    """

    @enforce_keys [
      :host_email,
      :amount_cents,
      :currency
    ]
    defstruct [
      :host_email,
      :host_name,
      :host_user_id,
      :amount_cents,
      :currency,
      :attendee_name,
      :attendee_email,
      :meeting_title,
      :stripe_charge_id,
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
            stripe_charge_id: String.t() | nil,
            reason: String.t() | nil
          }
  end

  @doc """
  The dispute alert, in the language of the host identified by
  `host_user_id` (the default locale when there is none).
  """
  @spec render(DisputeContext.t()) :: Swoosh.Email.t()
  def render(%DisputeContext{} = context) do
    RecipientLocale.with_user_id_locale(context.host_user_id, fn ->
      amount = Formatting.format_currency(context.amount_cents, context.currency)
      host = %{name: context.host_name}
      details = details(context, amount)

      MjmlEmail.base_email()
      |> to(recipient(context.host_name, context.host_email))
      |> subject(dgettext("emails_payments", "Stripe dispute opened: %{amount}", amount: amount))
      |> header("X-Priority", "1")
      |> html_body(html(host, amount, details))
      |> text_body(text(host, amount, details))
    end)
  end

  defp html(host, amount, details) do
    mjml_content = """
    #{Text.centered_html(Greeting.html(host), padding: "8px 0 4px 0", font_size: "16px")}

    #{Text.centered_text(intro(amount), padding: "0 0 16px 0")}

    #{Cards.details_card(Sanitise.sanitize_for_email(dgettext("emails_payments", "Dispute details")), details_html(details))}

    #{Text.section_title(dgettext("emails_payments", "What happens next?"))}
    #{Text.centered_text(next_steps(), padding: "0 0 14px 0")}
    #{Buttons.action_button(@intent, dgettext("emails_payments", "Open Stripe dashboard"), @stripe_disputes_url, full_width: true)}

    #{Text.system_footer_note(outcome())}
    """

    # This is a platform-to-host operational alert, not a message from an
    # organiser — use the system layout so no organiser strip is rendered.
    TemplateHelper.compile_system_template(
      mjml_content,
      dgettext("emails_payments", "Stripe dispute opened"),
      dgettext("emails_payments", "A cardholder has disputed one of your booking payments."),
      intent: @intent,
      eyebrow: dgettext("emails_payments", "Action required"),
      stage_title: dgettext("emails_payments", "A dispute was opened"),
      stage_subtitle:
        dgettext("emails_payments", "%{amount} disputed by the cardholder", amount: amount)
    )
  end

  defp text(host, amount, details) do
    Enum.join(
      [
        dgettext("emails_payments", "STRIPE DISPUTE OPENED"),
        "",
        Greeting.text(host),
        "",
        intro(amount),
        "",
        dgettext("emails_payments", "DISPUTE DETAILS:"),
        Enum.map_join(details, "\n", fn {label, value} -> "#{label} #{value}" end),
        "",
        dgettext("emails_payments", "WHAT HAPPENS NEXT:"),
        next_steps(),
        @stripe_disputes_url,
        "",
        outcome()
      ],
      "\n"
    )
  end

  # Only attach a display name when the host actually has one — otherwise a
  # nil name would surface a placeholder as the recipient's name.
  defp recipient(name, email) when is_binary(name) and name != "", do: {name, email}
  defp recipient(_name, email), do: email

  defp intro(amount),
    do:
      dgettext(
        "emails_payments",
        "Stripe has opened a dispute on a %{amount} payment for one of your bookings.",
        amount: amount
      )

  defp next_steps,
    do:
      dgettext(
        "emails_payments",
        "Stripe needs evidence from you within their stated deadline to challenge the dispute. Open the dispute in the Stripe dashboard to upload evidence or accept the dispute."
      )

  defp outcome,
    do:
      dgettext(
        "emails_payments",
        "If the dispute is closed in your favour, the booking will reconcile automatically. If lost, the booking is marked refunded."
      )

  # The dispute's facts as label and value, the same in both parts; a fact
  # the payment does not carry is left out.
  defp details(context, amount) do
    Enum.reject(
      [
        {dgettext("emails_payments", "Disputed amount:"), amount},
        {dgettext("emails_payments", "Attendee:"), context.attendee_name},
        {dgettext("emails_payments", "Attendee email:"), context.attendee_email},
        {dgettext("emails_payments", "Meeting:"), context.meeting_title},
        {dgettext("emails_payments", "Stripe charge:"), context.stripe_charge_id},
        {dgettext("emails_payments", "Stated reason:"), context.reason}
      ],
      fn {_label, value} -> is_nil(value) end
    )
  end

  # The amount, first, is the one fact set in bold.
  defp details_html([{label, amount} | rest]) do
    first =
      "#{Sanitise.sanitize_for_email(label)} <strong>#{Sanitise.sanitize_for_email(amount)}</strong>"

    Enum.join([first | Enum.map(rest, &detail_html/1)], "<br/>\n")
  end

  defp detail_html({label, value}),
    do: "#{Sanitise.sanitize_for_email(label)} #{Sanitise.sanitize_for_email(value)}"
end
