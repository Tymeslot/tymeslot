defmodule Tymeslot.Emails.Templates.EmailVerification do
  @moduledoc """
  Email template for user email verification.
  """
  alias Tymeslot.Emails.Shared.{Components, SharedHelpers, Styles, TemplateHelper}

  @spec render(%{name: String.t() | nil, email: String.t()}, String.t()) :: String.t()
  def render(user, verification_url) do
    mjml_content = """
    #{Components.title_section("Welcome to Tymeslot!")}

    <mj-text font-size="16px" color="#{Styles.text_color(:secondary)}" line-height="24px" padding-bottom="24px">
      Hi #{SharedHelpers.sanitize_for_email(user.name || user.email)},
    </mj-text>

    <mj-text font-size="16px" color="#{Styles.text_color(:secondary)}" line-height="24px" padding-bottom="32px">
      We're excited to have you on board! To start scheduling meetings and simplify your calendar, please verify your email address below.
    </mj-text>

    #{Components.action_button("Confirm Email & Get Started", verification_url)}

    <mj-text font-size="14px" color="#{Styles.text_color(:muted)}" padding-top="32px" line-height="20px">
      For your security, this link expires in 24 hours. If you didn't sign up for Tymeslot, no further action is needed.
    </mj-text>

    #{Components.divider()}

    <mj-text font-size="13px" color="#{Styles.text_color(:muted)}" line-height="20px">
      Having trouble with the button? Copy and paste this link into your browser:
    </mj-text>
    <mj-text font-size="12px" padding-top="8px">
      <a href="#{verification_url}" style="color: #14b8a6; text-decoration: underline; word-break: break-all;">
        #{verification_url}
      </a>
    </mj-text>
    """

    TemplateHelper.compile_system_template(mjml_content, "Account Verification")
  end
end
