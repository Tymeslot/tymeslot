defmodule Tymeslot.Emails.Templates.PasswordReset do
  @moduledoc """
  Email template for password reset requests.
  """
  alias Tymeslot.Emails.Shared.{Components, SharedHelpers, TemplateHelper}

  @spec render(map(), String.t()) :: String.t()
  def render(user, reset_url) do
    user_display_name = SharedHelpers.sanitize_for_email(user.name || user.email)

    mjml_content = """
    #{Components.title_section("Reset Your Password", emoji: "🔒", align: "center")}

    #{Components.centered_text("Hi #{user_display_name},")}

    #{Components.centered_text("It happens to the best of us! Click the button below to choose a new password and regain access to your account.", padding: "0 0 20px 0")}

    #{Components.action_button("Set New Password", reset_url, color: "primary", full_width: true)}

    #{Components.system_footer_note("This link is valid for the next 2 hours.")}

    #{Components.system_footer_note("If you didn't request this change, your account is still secure—you can simply delete this email.")}

    #{Components.divider(margin: "32px 0")}

    #{Components.troubleshooting_link(reset_url)}
    """

    TemplateHelper.compile_system_template(
      mjml_content,
      "Account Security",
      "Instructions to reset your Tymeslot password."
    )
  end

  @spec render_text(map(), String.t()) :: String.t()
  def render_text(user, reset_url) do
    name = user.name || user.email

    """
    Reset Your Password

    Hi #{name},

    It happens to the best of us! Click the link below to choose a new password and regain access to your account.

    Set New Password:
    #{reset_url}

    This link is valid for the next 2 hours.

    If you didn't request this change, your account is still secure — you can simply delete this email.
    """
  end
end
