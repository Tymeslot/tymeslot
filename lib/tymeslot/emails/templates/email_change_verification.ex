defmodule Tymeslot.Emails.Templates.EmailChangeVerification do
  @moduledoc """
  Email template for email change verification.
  Sent to the NEW email address to verify ownership.
  """
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Emails.Shared.{Buttons, Callouts, Sanitise, Styles, TemplateHelper, Text}

  # A confirmation-style action to finalise an account change.
  @intent :confirmed

  @spec render(Tymeslot.Emails.EmailService.user_map(), String.t(), String.t()) :: String.t()
  def render(user, new_email, verification_url) do
    name = user.name || user.email

    mjml_content = """
    #{Text.centered_text(dgettext("emails", "Hi %{name},", name: name),
    font_size: "16px",
    color: Styles.ink(),
    padding: "8px 0 4px 0")}

    #{Text.centered_text(dgettext("emails", "You asked to change the email address on your Tymeslot account. Confirm the new address below to finish the switch."),
    font_size: "15px",
    color: Styles.ink_soft(),
    padding: "0 0 22px 0")}

    #{new_email_card(new_email)}

    #{Buttons.action_button(@intent, dgettext("emails", "Verify New Email Address"), verification_url, full_width: true, size: :large)}

    #{Callouts.alert_box(@intent,
    dgettext("emails", "This link expires in 24 hours. Once confirmed, you'll sign in with your new email address."),
    title: dgettext("emails", "Heads up"))}

    #{Text.divider(margin: "24px 0 16px 0")}

    #{Text.centered_text(dgettext("emails", "Didn't request this change? You can safely ignore this email — nothing will happen to your account."),
    font_size: "13px",
    color: Styles.ink_muted(),
    padding: "0 0 14px 0")}

    #{Text.troubleshooting_link(verification_url)}
    """

    TemplateHelper.compile_system_template(
      mjml_content,
      dgettext("emails", "Verify your new email address"),
      dgettext("emails", "Confirm the new email address on your Tymeslot account."),
      intent: @intent,
      eyebrow: dgettext("emails", "Verify"),
      stage_title: dgettext("emails", "Confirm your new email"),
      stage_subtitle: dgettext("emails", "One click and the switch is done.")
    )
  end

  # A prominent card that pulls the new email address out of the body copy
  # — gives the reader a single unambiguous anchor to visually verify.
  defp new_email_card(email) do
    safe_email = Sanitise.sanitize_for_email(email)

    """
    <mj-section
      padding="0 0 22px 0"
    >
      <mj-column>
        <mj-text
          font-size="11px"
          font-weight="700"
          color="#{Styles.ink_muted()}"
          letter-spacing="0.14em"
          text-transform="uppercase"
          align="center"
          padding="0 0 10px 0"
          css-class="mobile-eyebrow"
        >
          #{dgettext("emails", "New email address")}
        </mj-text>
        <mj-text
          align="center"
          padding="0"
          font-size="0"
        >
          <span style="display: inline-block; padding: 14px 22px; border: 1px solid #{Styles.hairline()}; border-radius: #{Styles.radius(:md)}; background: #{Styles.canvas_soft()}; font-size: 18px; font-weight: 700; color: #{Styles.ink()}; letter-spacing: -0.01em; word-break: break-all; max-width: 100%;">#{safe_email}</span>
        </mj-text>
      </mj-column>
    </mj-section>
    """
  end

  @spec render_text(Tymeslot.Emails.EmailService.user_map(), String.t(), String.t()) :: String.t()
  def render_text(user, new_email, verification_url) do
    name = user.name || user.email

    """
    #{dgettext("emails", "Verify your new email address")}

    #{dgettext("emails", "Hi %{name},", name: name)}

    #{dgettext("emails", "You asked to change the email address on your Tymeslot account to %{new_email}.", new_email: new_email)}

    #{dgettext("emails", "To confirm this change, visit the link below:")}
    #{verification_url}

    #{dgettext("emails", "This link expires in 24 hours. Once confirmed, you'll sign in with your new email address.")}

    #{dgettext("emails", "Didn't request this change? You can safely ignore this email — nothing will happen to your account.")}
    """
  end
end
