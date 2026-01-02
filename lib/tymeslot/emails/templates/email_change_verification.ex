defmodule Tymeslot.Emails.Templates.EmailChangeVerification do
  @moduledoc """
  Email template for email change verification.
  Sent to the NEW email address to verify ownership.
  """
  alias Tymeslot.Emails.Shared.{Components, SharedHelpers, Styles, TemplateHelper}

  @spec render(map(), String.t(), String.t()) :: String.t()
  def render(user, new_email, verification_url) do
    mjml_content = """
    #{Components.title_section("Verify Your New Email Address")}

    <mj-text font-size="16px" color="#{Styles.text_color(:secondary)}" line-height="24px" padding-bottom="24px">
      Hi #{SharedHelpers.sanitize_for_email(user.name || user.email)},
    </mj-text>

    <mj-text font-size="16px" color="#{Styles.text_color(:secondary)}" line-height="24px" padding-bottom="16px">
      You've requested to change your Tymeslot email address to <strong>#{SharedHelpers.sanitize_for_email(new_email)}</strong>.
    </mj-text>

    <mj-text font-size="16px" color="#{Styles.text_color(:secondary)}" line-height="24px" padding-bottom="32px">
      To confirm this change, please click the button below to verify that you have access to this email address.
    </mj-text>

    #{Components.action_button("Verify New Email Address", verification_url)}

    #{Components.alert_box("info", "This verification link will expire in 24 hours. After verification, your email will be updated and you'll need to use the new email to sign in.")}

    <mj-text font-size="14px" color="#{Styles.text_color(:muted)}" padding-top="32px" line-height="20px">
      <strong>Important:</strong> If you didn't request this email change, please ignore this message. Your account will remain unchanged.
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

    TemplateHelper.compile_system_template(mjml_content, "Email Change Verification")
  end
end
