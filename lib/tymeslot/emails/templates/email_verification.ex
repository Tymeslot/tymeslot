defmodule Tymeslot.Emails.Templates.EmailVerification do
  @moduledoc """
  Email template for user email verification.
  """
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Emails.Shared.{Buttons, Greeting, TemplateHelper, Text}

  # A first-contact email welcoming a new user in.
  @intent :confirmed

  @spec render(Tymeslot.Emails.EmailService.user_map(), String.t()) :: String.t()
  def render(user, verification_url) do
    mjml_content = """
    #{Text.centered_html(Greeting.html(user), padding: "8px 0 4px 0", font_size: "16px")}

    #{Text.centered_text(dgettext("emails", "We're glad you're here. One quick step and your calendar will be ready to go - please confirm your email below."), padding: "0 0 20px 0")}

    #{Buttons.action_button(@intent, dgettext("emails", "Confirm Email & Get Started"), verification_url, full_width: true, size: :large)}

    #{Text.system_footer_note(dgettext("emails", "For your security, this link expires in 24 hours. If you didn't sign up for Tymeslot, you can ignore this email."))}

    #{Text.divider(margin: "28px 0 16px 0")}

    #{Text.troubleshooting_link(verification_url)}
    """

    TemplateHelper.compile_system_template(
      mjml_content,
      dgettext("emails", "Account Verification"),
      dgettext("emails", "Welcome to Tymeslot - please verify your email."),
      intent: @intent,
      eyebrow: dgettext("emails", "Welcome"),
      stage_title: dgettext("emails", "Welcome to Tymeslot"),
      stage_subtitle: dgettext("emails", "Let's get you scheduling in under a minute.")
    )
  end

  @spec render_text(Tymeslot.Emails.EmailService.user_map(), String.t()) :: String.t()
  def render_text(user, verification_url) do
    """
    #{dgettext("emails", "Welcome to Tymeslot!")}

    #{Greeting.text(user)}

    #{dgettext("emails", "We're excited to have you on board! To start scheduling meetings and simplify your calendar, please verify your email address.")}

    #{dgettext("emails", "Confirm Email & Get Started:")}
    #{verification_url}

    #{dgettext("emails", "For your security, this link expires in 24 hours. If you didn't sign up for Tymeslot, no further action is needed.")}
    """
  end
end
