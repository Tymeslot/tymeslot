defmodule Tymeslot.Emails.Templates.PasswordReset do
  @moduledoc """
  Email template for password reset requests.
  """
  alias Tymeslot.Emails.Shared.{Components, SharedHelpers, Styles, TemplateHelper}

  @spec render(%{name: String.t() | nil, email: String.t()}, String.t()) :: String.t()
  def render(user, reset_url) do
    mjml_content = """
    #{Components.title_section("Securely reset your password")}

    <mj-text font-size="16px" color="#{Styles.text_color(:secondary)}" line-height="24px" padding-bottom="24px">
      Hi #{SharedHelpers.sanitize_for_email(user.name || user.email)},
    </mj-text>

    <mj-text font-size="16px" color="#{Styles.text_color(:secondary)}" line-height="24px" padding-bottom="24px">
      It happens to the best of us! Click the button below to choose a new password and regain access to your account.
    </mj-text>

    #{Components.action_button("Set New Password", reset_url)}

    <mj-text font-size="14px" color="#{Styles.text_color(:secondary)}" padding-top="24px" line-height="20px">
      This link is valid for the next 2 hours.
    </mj-text>

    <mj-text font-size="14px" color="#{Styles.text_color(:secondary)}" padding-top="16px" line-height="20px">
      If you didn't request this change, your account is still secure—you can simply delete this email.
    </mj-text>

    #{Components.divider()}

    <mj-text font-size="12px" color="#{Styles.text_color(:muted)}" line-height="18px">
      If the button doesn't work, copy and paste this link into your browser:
      <br />
      <a href="#{reset_url}" style="color: #14b8a6; text-decoration: underline;">
        #{reset_url}
      </a>
    </mj-text>
    """

    TemplateHelper.compile_system_template(mjml_content, "Account Security")
  end
end
