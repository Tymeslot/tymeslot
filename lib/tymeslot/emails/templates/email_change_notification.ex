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

    #{Text.centered_text(dgettext("emails_account",
    "A request has been made to change the email address on your Tymeslot account. We're letting you know so you can confirm it was you."),
    padding: "0 0 20px 0")}

    #{Callouts.alert_box(@intent,
    dgettext("emails_account", "Email change requested to: %{new_email}", new_email: new_email))}

    #{Cards.contact_details_card(dgettext("emails_account", "Request details"), [%{label: dgettext("emails_account", "New email"), value: new_email}, %{label: dgettext("emails_account", "Current email"), value: user.email}, %{label: dgettext("emails_account", "Requested at"), value: format_time(request_time)}, %{label: dgettext("emails_account", "Status"), value: dgettext("emails_account", "Pending verification")}])}

    #{Text.section_title(dgettext("emails_account", "What happens next"), padding: "24px 0 8px 0")}

    #{Text.bullet_list([dgettext("emails_account", "A verification email has been sent to the new address"), dgettext("emails_account", "The change will only be completed after verification"), dgettext("emails_account", "The verification link expires in 24 hours"), dgettext("emails_account", "Your current email remains active until the change is confirmed")])}

    #{Callouts.alert_box(:cancelled,
    dgettext("emails_account", "If you did not request this change, your account may be compromised. Please sign in to your account immediately and change your password."),
    title: dgettext("emails_account", "Didn't request this?"))}

    #{Text.system_footer_note(dgettext("emails_account", "This is a security notification sent to protect your account. If you have concerns, please contact support immediately."))}
    """

    TemplateHelper.compile_system_template(
      mjml_content,
      dgettext("emails_account", "Security notification"),
      dgettext("emails_account", "A change was requested on your Tymeslot account."),
      intent: @intent,
      eyebrow: dgettext("emails_account", "Security"),
      stage_title: dgettext("emails_account", "Email change requested"),
      stage_subtitle: dgettext("emails_account", "We're letting you know in case it wasn't you.")
    )
  end

  @spec render_text(Tymeslot.Emails.EmailService.user_map(), String.t(), DateTime.t() | nil) ::
          String.t()
  def render_text(user, new_email, request_time) do
    """
    #{dgettext("emails_account", "Email change requested")}

    #{Greeting.text(user)}

    #{dgettext("emails_account",
    "A request has been made to change the email address on your Tymeslot account. We're letting you know so you can confirm it was you.")}

    #{dgettext("emails_account", "REQUEST DETAILS:")}
    #{dgettext("emails_account", "New email:")} #{new_email}
    #{dgettext("emails_account", "Current email:")} #{user.email}
    #{dgettext("emails_account", "Requested at:")} #{format_time(request_time)}
    #{dgettext("emails_account", "Status:")} #{dgettext("emails_account", "Pending verification")}

    #{dgettext("emails_account", "WHAT HAPPENS NEXT:")}
    - #{dgettext("emails_account", "A verification email has been sent to the new address")}
    - #{dgettext("emails_account", "The change will only be completed after verification")}
    - #{dgettext("emails_account", "The verification link expires in 24 hours")}
    - #{dgettext("emails_account", "Your current email remains active until the change is confirmed")}

    #{dgettext("emails_account", "If you did not request this change, your account may be compromised. Please sign in to your account immediately and change your password.")}
    """
  end

  defp format_time(nil), do: dgettext("emails_account", "Just now")

  defp format_time(datetime) do
    Formatting.format_datetime(datetime, Gettext.get_locale(TymeslotWeb.Gettext))
  end
end
