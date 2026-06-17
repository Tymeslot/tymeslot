defmodule Tymeslot.Emails.Templates.ChargeDisputeOpened do
  @moduledoc """
  Host-facing email sent when Stripe opens a dispute against a charge linked
  to one of their booking payments. English-only (host operational alert).

  Built from a normalised `DisputeContext` struct so raw Stripe payloads do
  not leak into the template layer.
  """

  import Swoosh.Email

  alias Tymeslot.Emails.Shared.{
    Buttons,
    Formatting,
    MjmlEmail,
    Sanitise,
    Styles,
    TemplateHelper,
    Text
  }

  @intent :cancelled
  @stripe_disputes_url "https://dashboard.stripe.com/disputes"

  defmodule DisputeContext do
    @moduledoc """
    Normalised data for the dispute email. Includes the host's contact info
    so the worker can pass everything the template needs in one struct.
    """

    @enforce_keys [
      :host_email,
      :amount_cents,
      :currency
    ]
    defstruct [
      :host_email,
      :host_name,
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
            amount_cents: pos_integer(),
            currency: String.t(),
            attendee_name: String.t() | nil,
            attendee_email: String.t() | nil,
            meeting_title: String.t() | nil,
            stripe_charge_id: String.t() | nil,
            reason: String.t() | nil
          }
  end

  @spec render(DisputeContext.t()) :: Swoosh.Email.t()
  def render(%DisputeContext{} = context) do
    amount = Formatting.format_currency(context.amount_cents, context.currency)
    greeting_name = context.host_name || "there"

    intro =
      "Hi #{Sanitise.sanitize_for_email(greeting_name)} — Stripe has opened a dispute on a #{Sanitise.sanitize_for_email(amount)} payment for one of your bookings."

    mjml_content = """
    #{Text.centered_text(intro, padding: "8px 0 16px 0")}

    #{dispute_details_card(context, amount)}

    #{Text.section_title("What happens next?")}
    #{Text.centered_text("Stripe needs evidence from you within their stated deadline to challenge the dispute. Open the dispute in the Stripe dashboard to upload evidence or accept the dispute.", padding: "0 0 14px 0")}
    #{Buttons.action_button(@intent, "Open Stripe dashboard", @stripe_disputes_url, full_width: true)}

    #{Text.system_footer_note("If the dispute is closed in your favour, the booking will reconcile automatically. If lost, the booking is marked refunded.")}
    """

    # This is a platform-to-host operational alert, not a message from an
    # organiser — use the system layout so no organiser strip is rendered.
    html_body =
      TemplateHelper.compile_system_template(
        mjml_content,
        "Stripe dispute opened",
        "A cardholder has disputed one of your booking payments.",
        intent: @intent,
        eyebrow: "Action required",
        stage_title: "A dispute was opened",
        stage_subtitle: "#{amount} disputed by the cardholder"
      )

    MjmlEmail.base_email()
    |> to(recipient(context.host_name, context.host_email))
    |> subject("Stripe dispute opened — #{amount}")
    |> header("X-Priority", "1")
    |> html_body(html_body)
    |> text_body(text_body(context, amount, greeting_name))
  end

  # Only attach a display name when the host actually has one — otherwise a
  # nil name would surface a placeholder as the recipient's name.
  defp recipient(name, email) when is_binary(name) and name != "", do: {name, email}
  defp recipient(_name, email), do: email

  defp dispute_details_card(context, amount) do
    label = Sanitise.sanitize_for_email("Dispute details")

    lines =
      [
        "Disputed amount: <strong>#{Sanitise.sanitize_for_email(amount)}</strong>",
        if(context.attendee_name,
          do: "Attendee: #{Sanitise.sanitize_for_email(context.attendee_name)}"
        ),
        if(context.attendee_email,
          do: "Attendee email: #{Sanitise.sanitize_for_email(context.attendee_email)}"
        ),
        if(context.meeting_title,
          do: "Meeting: #{Sanitise.sanitize_for_email(context.meeting_title)}"
        ),
        if(context.stripe_charge_id,
          do: "Stripe charge: #{Sanitise.sanitize_for_email(context.stripe_charge_id)}"
        ),
        if(context.reason,
          do: "Stated reason: #{Sanitise.sanitize_for_email(context.reason)}"
        )
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("<br/>\n")

    """
    #{Text.section_title(label)}
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
          #{lines}
        </mj-text>
      </mj-column>
    </mj-section>
    """
  end

  defp text_body(context, amount, host_name) do
    [
      "STRIPE DISPUTE OPENED",
      "",
      "Hi #{host_name}, Stripe has opened a dispute on a #{amount} payment for one of your bookings.",
      "",
      "DISPUTE DETAILS:",
      "Disputed amount: #{amount}",
      context.attendee_name && "Attendee: #{context.attendee_name}",
      context.attendee_email && "Attendee email: #{context.attendee_email}",
      context.meeting_title && "Meeting: #{context.meeting_title}",
      context.stripe_charge_id && "Stripe charge: #{context.stripe_charge_id}",
      context.reason && "Stated reason: #{context.reason}",
      "",
      "WHAT HAPPENS NEXT:",
      "Stripe needs evidence from you within their stated deadline to challenge the dispute.",
      "Open the dispute in the Stripe dashboard to upload evidence or accept the dispute:",
      @stripe_disputes_url,
      "",
      "If the dispute is closed in your favour, the booking will reconcile automatically.",
      "If lost, the booking is marked refunded."
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end
end
