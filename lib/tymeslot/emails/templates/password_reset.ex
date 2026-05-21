defmodule Tymeslot.Emails.Templates.PasswordReset do
  @moduledoc """
  Email template for password reset requests.
  """
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Emails.Shared.{Buttons, Greeting, TemplateHelper, Text}

  # A security-sensitive action that warrants the reader's attention.
  @intent :alert

  @spec render(Tymeslot.Emails.EmailService.user_map(), String.t()) :: String.t()
  def render(user, reset_url) do
    mjml_content = """
    #{Text.centered_text(Greeting.html(user), padding: "8px 0 4px 0", font_size: "16px")}

    #{Text.centered_text(dgettext("emails", "It happens to the best of us. Click the button below to choose a new password and pick up where you left off."), padding: "0 0 20px 0")}

    #{Buttons.action_button(@intent, dgettext("emails", "Set New Password"), reset_url, full_width: true, size: :large)}

    #{Text.system_footer_note(dgettext("emails", "This link is valid for the next 2 hours."))}
    #{Text.system_footer_note(dgettext("emails", "If you didn't request this change, your account is still secure — you can simply delete this email."))}

    #{Text.divider(margin: "28px 0 16px 0")}

    #{Text.troubleshooting_link(reset_url)}
    """

    TemplateHelper.compile_system_template(
      mjml_content,
      dgettext("emails", "Account Security"),
      dgettext("emails", "Instructions to reset your Tymeslot password."),
      intent: @intent,
      eyebrow: dgettext("emails", "Security"),
      stage_title: dgettext("emails", "Reset your password"),
      stage_subtitle: dgettext("emails", "A fresh password and you're back in.")
    )
  end

  @spec render_text(Tymeslot.Emails.EmailService.user_map(), String.t()) :: String.t()
  def render_text(user, reset_url) do
    """
    #{dgettext("emails", "Reset Your Password")}

    #{Greeting.text(user)}

    #{dgettext("emails", "It happens to the best of us! Click the link below to choose a new password and regain access to your account.")}

    #{dgettext("emails", "Set New Password:")}
    #{reset_url}

    #{dgettext("emails", "This link is valid for the next 2 hours.")}

    #{dgettext("emails", "If you didn't request this change, your account is still secure — you can simply delete this email.")}
    """
  end
end
