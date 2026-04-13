defmodule Tymeslot.Emails.Templates.EmailChangeNotification do
  @moduledoc """
  Email template for notifying the current email address about an email change request.
  Sent to the OLD email address as a security notification.
  """
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Emails.Shared.{Callouts, Cards, Sanitise, TemplateHelper, Text}

  # A security-sensitive notification about a potentially unauthorised change.
  @intent :alert

  @spec render(Tymeslot.Emails.EmailService.user_map(), String.t(), DateTime.t() | nil) ::
          String.t()
  def render(user, new_email, request_time) do
    safe_name = Sanitise.sanitize_for_email(user.name || user.email)
    safe_new_email = Sanitise.sanitize_for_email(new_email)
    safe_current_email = Sanitise.sanitize_for_email(user.email)

    mjml_content = """
    #{Text.centered_text(dgettext("emails",
    "Hi %{name}, a request has been made to change the email address on your Tymeslot account. We're letting you know so you can confirm it was you.",
    name: safe_name),
    padding: "8px 0 20px 0")}

    #{Callouts.alert_box(@intent,
    dgettext("emails", "Email change requested to: %{new_email}", new_email: safe_new_email))}

    #{Cards.contact_details_card(dgettext("emails", "Request details"), "", [%{label: dgettext("emails", "New email"), value: safe_new_email}, %{label: dgettext("emails", "Current email"), value: safe_current_email}, %{label: dgettext("emails", "Requested at"), value: format_time(request_time)}, %{label: dgettext("emails", "Status"), value: dgettext("emails", "Pending verification")}])}

    #{Text.section_title(dgettext("emails", "What happens next"), padding: "24px 0 8px 0")}

    #{bullet_list([dgettext("emails", "A verification email has been sent to the new address"), dgettext("emails", "The change will only be completed after verification"), dgettext("emails", "The verification link expires in 24 hours"), dgettext("emails", "Your current email remains active until the change is confirmed")])}

    #{Callouts.alert_box(:cancelled,
    dgettext("emails", "If you did not request this change, your account may be compromised. Please sign in to your account immediately and change your password."),
    title: dgettext("emails", "Didn't request this?"))}

    #{Text.system_footer_note(dgettext("emails", "This is a security notification sent to protect your account. If you have concerns, please contact support immediately."))}
    """

    TemplateHelper.compile_system_template(
      mjml_content,
      dgettext("emails", "Security notification"),
      dgettext("emails", "A change was requested on your Tymeslot account."),
      intent: @intent,
      eyebrow: dgettext("emails", "Security"),
      stage_title: dgettext("emails", "Email change requested"),
      stage_subtitle: dgettext("emails", "We're letting you know in case it wasn't you.")
    )
  end

  @spec render_text(Tymeslot.Emails.EmailService.user_map(), String.t(), DateTime.t() | nil) ::
          String.t()
  def render_text(user, new_email, request_time) do
    name = user.name || user.email

    """
    #{dgettext("emails", "Email change requested")}

    #{dgettext("emails",
    "Hi %{name}, a request has been made to change the email address on your Tymeslot account. We're letting you know so you can confirm it was you.",
    name: name)}

    #{dgettext("emails", "REQUEST DETAILS:")}
    #{dgettext("emails", "New email:")} #{new_email}
    #{dgettext("emails", "Current email:")} #{user.email}
    #{dgettext("emails", "Requested at:")} #{format_time(request_time)}
    #{dgettext("emails", "Status:")} #{dgettext("emails", "Pending verification")}

    #{dgettext("emails", "WHAT HAPPENS NEXT:")}
    - #{dgettext("emails", "A verification email has been sent to the new address")}
    - #{dgettext("emails", "The change will only be completed after verification")}
    - #{dgettext("emails", "The verification link expires in 24 hours")}
    - #{dgettext("emails", "Your current email remains active until the change is confirmed")}

    #{dgettext("emails", "If you did not request this change, your account may be compromised. Please sign in to your account immediately and change your password.")}
    """
  end

  defp bullet_list(items) do
    bullets =
      Enum.map_join(items, "<br/>\n", fn item -> "• #{item}" end)

    """
    <mj-section padding="0 0 8px 0">
      <mj-column>
        <mj-text font-size="15px" color="#{Tymeslot.Emails.Shared.Styles.ink_soft()}" line-height="1.7" padding="0">
          #{bullets}
        </mj-text>
      </mj-column>
    </mj-section>
    """
  end

  defp format_time(nil), do: dgettext("emails", "Just now")

  defp format_time(datetime) do
    Calendar.strftime(datetime, "%B %d, %Y at %I:%M %p %Z")
  end
end
