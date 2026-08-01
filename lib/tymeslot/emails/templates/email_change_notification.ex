defmodule Tymeslot.Emails.Templates.EmailChangeNotification do
  @moduledoc """
  Email template for notifying the current email address about an email change request.
  Sent to the OLD email address as a security notification.
  """
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Emails.Shared.{Callouts, Cards, Formatting, Greeting, TemplateHelper, Text}

  # A security-sensitive notification about a potentially unauthorised change.
  @intent :alert

  @spec render(Tymeslot.Emails.EmailService.user_map(), String.t(), DateTime.t() | nil) ::
          String.t()
  def render(user, new_email, request_time) do
    mjml_content = """
    #{Text.centered_html(Greeting.html(user), padding: "8px 0 4px 0", font_size: "16px")}

    #{Text.centered_text(dgettext("emails",
    "A request has been made to change the email address on your Tymeslot account. We're letting you know so you can confirm it was you."),
    padding: "0 0 20px 0")}

    #{Callouts.alert_box(@intent,
    dgettext("emails", "Email change requested to: %{new_email}", new_email: new_email))}

    #{Cards.contact_details_card(dgettext("emails", "Request details"), [%{label: dgettext("emails", "New email"), value: new_email}, %{label: dgettext("emails", "Current email"), value: user.email}, %{label: dgettext("emails", "Requested at"), value: format_time(request_time)}, %{label: dgettext("emails", "Status"), value: dgettext("emails", "Pending verification")}])}

    #{Text.section_title(dgettext("emails", "What happens next"), padding: "24px 0 8px 0")}

    #{Text.bullet_list([dgettext("emails", "A verification email has been sent to the new address"), dgettext("emails", "The change will only be completed after verification"), dgettext("emails", "The verification link expires in 24 hours"), dgettext("emails", "Your current email remains active until the change is confirmed")])}

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
    """
    #{dgettext("emails", "Email change requested")}

    #{Greeting.text(user)}

    #{dgettext("emails",
    "A request has been made to change the email address on your Tymeslot account. We're letting you know so you can confirm it was you.")}

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

  defp format_time(nil), do: dgettext("emails", "Just now")

  defp format_time(datetime) do
    Formatting.format_datetime(datetime, Gettext.get_locale(TymeslotWeb.Gettext))
  end
end
