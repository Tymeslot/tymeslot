defmodule Tymeslot.Emails.Templates.EmailChangeNotification do
  @moduledoc """
  Email template for notifying the current email address about an email change request.
  Sent to the OLD email address as a security notification.
  """
  alias Tymeslot.Emails.Shared.{Components, SharedHelpers, Styles, TemplateHelper}

  @spec render(map(), String.t(), DateTime.t() | nil) :: String.t()
  def render(user, new_email, request_time) do
    mjml_content = """
    #{Components.title_section("Email Change Request Notification")}

    <mj-text font-size="16px" color="#{Styles.text_color(:secondary)}" line-height="24px" padding-bottom="24px">
      Hi #{SharedHelpers.sanitize_for_email(user.name || user.email)},
    </mj-text>

    <mj-text font-size="16px" color="#{Styles.text_color(:secondary)}" line-height="24px" padding-bottom="24px">
      This is a security notification to inform you that a request has been made to change your Tymeslot account email address.
    </mj-text>

    #{Components.alert_box("warning", "Email change requested to: #{SharedHelpers.sanitize_for_email(new_email)}")}

    <mj-text font-size="15px" color="#{Styles.text_color(:secondary)}" line-height="22px" padding-top="24px" padding-bottom="16px">
      <strong>Request Details:</strong>
    </mj-text>

    <mj-text font-size="14px" color="#{Styles.text_color(:muted)}" line-height="20px" padding-bottom="4px">
      New Email:
    </mj-text>
    <mj-text font-size="14px" color="#{Styles.text_color(:primary)}" line-height="20px" padding-bottom="12px" font-weight="500">
      #{SharedHelpers.sanitize_for_email(new_email)}
    </mj-text>

    <mj-text font-size="14px" color="#{Styles.text_color(:muted)}" line-height="20px" padding-bottom="4px">
      Requested At:
    </mj-text>
    <mj-text font-size="14px" color="#{Styles.text_color(:primary)}" line-height="20px" padding-bottom="12px">
      #{format_time(request_time)}
    </mj-text>

    <mj-text font-size="14px" color="#{Styles.text_color(:muted)}" line-height="20px" padding-bottom="4px">
      Current Email:
    </mj-text>
    <mj-text font-size="14px" color="#{Styles.text_color(:primary)}" line-height="20px" padding-bottom="12px">
      #{SharedHelpers.sanitize_for_email(user.email)}
    </mj-text>

    <mj-text font-size="14px" color="#{Styles.text_color(:muted)}" line-height="20px" padding-bottom="4px">
      Status:
    </mj-text>
    <mj-text font-size="14px" color="#{Styles.text_color(:primary)}" line-height="20px" padding-bottom="16px">
      Pending Verification
    </mj-text>

    <mj-text font-size="16px" color="#{Styles.text_color(:secondary)}" line-height="24px" padding-top="24px" padding-bottom="16px">
      <strong>What happens next?</strong>
    </mj-text>

    <mj-text font-size="15px" color="#{Styles.text_color(:secondary)}" line-height="22px" padding-bottom="24px">
      • A verification email has been sent to the new address<br/>
      • The change will only be completed after verification<br/>
      • The verification link expires in 24 hours<br/>
      • Your current email remains active until the change is confirmed
    </mj-text>

    #{Components.alert_box("error", "If you did NOT request this change, your account may be compromised. Please sign in to your account immediately and change your password.")}

    <mj-text font-size="14px" color="#{Styles.text_color(:muted)}" padding-top="24px" line-height="20px">
      If you initiated this change, no further action is required on this email address. You'll need to verify the new email address to complete the change.
    </mj-text>

    #{Components.divider()}

    <mj-text font-size="13px" color="#{Styles.text_color(:muted)}" line-height="20px" align="center">
      This is a security notification sent to protect your account. If you have concerns, please contact support immediately.
    </mj-text>
    """

    TemplateHelper.compile_system_template(mjml_content, "Security Alert")
  end

  defp format_time(nil), do: "Just now"

  defp format_time(datetime) do
    Calendar.strftime(datetime, "%B %d, %Y at %I:%M %p %Z")
  end
end
