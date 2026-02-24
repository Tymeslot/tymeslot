defmodule Tymeslot.Emails.Templates.EmailVerification do
  @moduledoc """
  Email template for user email verification.
  """
  alias Tymeslot.Emails.Shared.{Components, SharedHelpers, TemplateHelper}

  @spec render(map(), String.t()) :: String.t()
  def render(user, verification_url) do
    user_display_name = SharedHelpers.sanitize_for_email(user.name || user.email)

    mjml_content = """
    #{Components.title_section("Welcome to Tymeslot!", emoji: "👋", align: "center")}

    #{Components.centered_text("Hi #{user_display_name},")}

    #{Components.centered_text("We're excited to have you on board! To start scheduling meetings and simplify your calendar, please verify your email address.", padding: "0 0 20px 0")}

    #{Components.action_button("Confirm Email & Get Started", verification_url, color: "primary", full_width: true)}

    #{Components.system_footer_note("For your security, this link expires in 24 hours. If you didn't sign up for Tymeslot, no further action is needed.")}

    #{Components.divider(margin: "32px 0")}

    #{Components.troubleshooting_link(verification_url)}
    """

    TemplateHelper.compile_system_template(
      mjml_content,
      "Account Verification",
      "Welcome to Tymeslot! Please verify your email."
    )
  end

  @spec render_text(map(), String.t()) :: String.t()
  def render_text(user, verification_url) do
    name = user.name || user.email

    """
    Welcome to Tymeslot!

    Hi #{name},

    We're excited to have you on board! To start scheduling meetings and simplify your calendar, please verify your email address.

    Confirm Email & Get Started:
    #{verification_url}

    For your security, this link expires in 24 hours. If you didn't sign up for Tymeslot, no further action is needed.
    """
  end
end
