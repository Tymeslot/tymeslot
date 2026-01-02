defmodule Tymeslot.Emails.Templates.EmailChangeConfirmed do
  @moduledoc """
  Email template for confirming a successful email change.
  Sent to BOTH the old and new email addresses after verification.
  """
  alias Tymeslot.Emails.Shared.{Components, SharedHelpers, Styles, TemplateHelper}

  @spec render(map(), String.t(), String.t(), DateTime.t() | nil, boolean()) :: String.t()
  def render(user, old_email, new_email, confirmed_time, is_old_email \\ false) do
    recipient_notice =
      if is_old_email do
        """
        <mj-text font-size="14px" color="#{Styles.text_color(:muted)}" padding-bottom="24px" background-color="#fef3c7" padding="12px" border-radius="6px">
          <strong>Note:</strong> This notification is being sent to your previous email address for security purposes.
        </mj-text>
        """
      else
        ""
      end

    mjml_content = """
    #{Components.title_section("Email Change Confirmed")}

    <mj-text font-size="16px" color="#{Styles.text_color(:secondary)}" line-height="24px" padding-bottom="24px">
      Hi #{SharedHelpers.sanitize_for_email(user.name || new_email)},
    </mj-text>

    #{recipient_notice}

    <mj-text font-size="16px" color="#{Styles.text_color(:secondary)}" line-height="24px" padding-bottom="24px">
      Your Tymeslot account email address has been successfully changed.
    </mj-text>

    #{Components.alert_box("success", "Email change completed successfully!")}

    <mj-text font-size="15px" color="#{Styles.text_color(:secondary)}" line-height="22px" padding-top="24px" padding-bottom="16px">
      <strong>Change Details:</strong>
    </mj-text>

    <mj-text font-size="14px" color="#{Styles.text_color(:muted)}" line-height="20px" padding-bottom="4px">
      Previous Email:
    </mj-text>
    <mj-text font-size="14px" color="#{Styles.text_color(:primary)}" line-height="20px" padding-bottom="12px">
      #{SharedHelpers.sanitize_for_email(old_email)}
    </mj-text>

    <mj-text font-size="14px" color="#{Styles.text_color(:muted)}" line-height="20px" padding-bottom="4px">
      New Email:
    </mj-text>
    <mj-text font-size="14px" color="#{Styles.text_color(:primary)}" line-height="20px" padding-bottom="12px" font-weight="500">
      #{SharedHelpers.sanitize_for_email(new_email)}
    </mj-text>

    <mj-text font-size="14px" color="#{Styles.text_color(:muted)}" line-height="20px" padding-bottom="4px">
      Changed At:
    </mj-text>
    <mj-text font-size="14px" color="#{Styles.text_color(:primary)}" line-height="20px" padding-bottom="12px">
      #{format_time(confirmed_time)}
    </mj-text>

    <mj-text font-size="14px" color="#{Styles.text_color(:muted)}" line-height="20px" padding-bottom="4px">
      Status:
    </mj-text>
    <mj-text font-size="14px" color="#{Styles.text_color(:primary)}" line-height="20px" padding-bottom="16px">
      Active
    </mj-text>

    <mj-text font-size="16px" color="#{Styles.text_color(:secondary)}" line-height="24px" padding-top="24px" padding-bottom="16px">
      <strong>What you need to know:</strong>
    </mj-text>

    <mj-text font-size="15px" color="#{Styles.text_color(:secondary)}" line-height="22px" padding-bottom="24px">
      • Use <strong>#{SharedHelpers.sanitize_for_email(new_email)}</strong> to sign in from now on<br/>
      • All future emails will be sent to your new address<br/>
      • Your meetings and settings remain unchanged<br/>
      • You may need to sign in again on other devices
    </mj-text>

    #{if is_old_email do
      Components.alert_box("warning", "If you did NOT authorize this change, please contact support immediately. You will no longer receive emails at this address.")
    else
      Components.alert_box("info", "For security reasons, we've also sent a copy of this confirmation to your previous email address.")
    end}

    #{Components.divider()}

    <mj-text font-size="13px" color="#{Styles.text_color(:muted)}" line-height="20px" align="center">
      This is a confirmation of changes made to your account. If you have any questions, please contact support.
    </mj-text>
    """

    TemplateHelper.compile_system_template(mjml_content, "Account Update")
  end

  defp format_time(nil), do: "Just now"

  defp format_time(datetime) do
    Calendar.strftime(datetime, "%B %d, %Y at %I:%M %p %Z")
  end
end
