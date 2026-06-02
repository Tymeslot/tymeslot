defmodule Tymeslot.Emails.Templates.ConnectAccountRestricted do
  @moduledoc """
  Host-facing email sent when Stripe transitions a Connect account into a
  restricted state — for example, missing capability information, identity
  verification needed, or platform suspension.

  English-only host operational alert.
  """

  import Swoosh.Email

  alias Tymeslot.Emails.Shared.{
    Buttons,
    MjmlEmail,
    Sanitise,
    Styles,
    TemplateHelper,
    Text
  }

  @intent :cancelled

  defmodule RestrictionContext do
    @moduledoc """
    Normalised data for the account-restricted email. The worker looks up the
    user and Stripe account state once and hands a flat struct to the template.
    """

    @enforce_keys [:host_email, :disabled_reason]
    defstruct [
      :host_email,
      :host_name,
      :disabled_reason,
      :previous_disabled_reason,
      :charges_enabled,
      :payouts_enabled,
      :dashboard_url
    ]

    @type t :: %__MODULE__{
            host_email: String.t(),
            host_name: String.t() | nil,
            disabled_reason: String.t(),
            previous_disabled_reason: String.t() | nil,
            charges_enabled: boolean() | nil,
            payouts_enabled: boolean() | nil,
            dashboard_url: String.t() | nil
          }
  end

  @spec render(RestrictionContext.t()) :: Swoosh.Email.t()
  def render(%RestrictionContext{} = context) do
    host_name = context.host_name || "there"
    reason_label = humanise_reason(context.disabled_reason)
    dashboard_url = context.dashboard_url || "https://dashboard.stripe.com/"

    intro =
      "Hi #{Sanitise.sanitize_for_email(host_name)} — Stripe has flagged your connected account as restricted. New paid bookings will continue to work only while charges remain enabled, so please act on this promptly."

    mjml_content = """
    #{Text.centered_text(intro, padding: "8px 0 16px 0")}

    #{restriction_card(context, reason_label)}

    #{Text.section_title("Restore your account")}
    #{Text.centered_text("Open the Stripe dashboard to see exactly what Stripe needs from you and complete any outstanding requirements.", padding: "0 0 14px 0")}
    #{Buttons.action_button(@intent, "Open Stripe dashboard", dashboard_url, full_width: true)}

    #{Text.system_footer_note("Once Stripe is satisfied, your account state updates automatically — no further action is needed on Tymeslot's side.")}
    """

    organizer_details =
      TemplateHelper.build_organizer_details(
        %{
          organizer_name: host_name,
          organizer_email: context.host_email,
          organizer_title: nil,
          organizer_avatar_url: nil
        },
        intent: @intent,
        eyebrow: "Action required",
        stage_title: "Your Stripe account is restricted",
        stage_subtitle: reason_label
      )

    html_body = TemplateHelper.compile_template(mjml_content, organizer_details)

    MjmlEmail.base_email()
    |> to({host_name, context.host_email})
    |> subject("Stripe account restricted — action required")
    |> header("X-Priority", "1")
    |> html_body(html_body)
    |> text_body(text_body(context, host_name, reason_label, dashboard_url))
  end

  defp restriction_card(context, reason_label) do
    label = Sanitise.sanitize_for_email("Account status")

    lines =
      [
        "Restriction: <strong>#{Sanitise.sanitize_for_email(reason_label)}</strong>",
        if(context.charges_enabled != nil,
          do: "Charges enabled: #{enabled_label(context.charges_enabled)}"
        ),
        if(context.payouts_enabled != nil,
          do: "Payouts enabled: #{enabled_label(context.payouts_enabled)}"
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

  defp text_body(context, host_name, reason_label, dashboard_url) do
    [
      "STRIPE ACCOUNT RESTRICTED",
      "",
      "Hi #{host_name}, Stripe has flagged your connected account as restricted.",
      "",
      "ACCOUNT STATUS:",
      "Restriction: #{reason_label}",
      context.charges_enabled != nil &&
        "Charges enabled: #{enabled_label(context.charges_enabled)}",
      context.payouts_enabled != nil &&
        "Payouts enabled: #{enabled_label(context.payouts_enabled)}",
      "",
      "RESTORE YOUR ACCOUNT:",
      "Open the Stripe dashboard to see what Stripe needs from you:",
      dashboard_url,
      "",
      "Once Stripe is satisfied, your account state updates automatically — no further action is needed on Tymeslot's side."
    ]
    |> Enum.reject(&(&1 in [nil, false]))
    |> Enum.join("\n")
  end

  defp enabled_label(true), do: "yes"
  defp enabled_label(false), do: "no"
  defp enabled_label(_other), do: "unknown"

  # Stripe's `disabled_reason` strings are dot-separated machine codes (e.g.
  # "requirements.past_due", "rejected.fraud"). Show them as-is so the host
  # can match the wording against Stripe's own dashboard messages.
  defp humanise_reason(reason) when is_binary(reason) and reason != "", do: reason
  defp humanise_reason(_reason), do: "Account restricted"
end
