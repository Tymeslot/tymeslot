defmodule Tymeslot.Emails.Templates.EmailChangeConfirmed do
  @moduledoc """
  Email template for confirming a successful email change.
  Sent to BOTH the old and new email addresses after verification.
  """
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Emails.Shared.{Callouts, Cards, Formatting, Greeting, TemplateHelper, Text}

  # A positive confirmation that an account change succeeded.
  @intent :confirmed

  @spec render(
          Tymeslot.Emails.EmailService.user_map(),
          String.t(),
          String.t(),
          DateTime.t() | nil,
          boolean()
        ) :: String.t()
  def render(user, old_email, new_email, confirmed_time, is_old_email \\ false) do
    intro =
      if is_old_email do
        dgettext(
          "emails",
          "Your Tymeslot account email address has been successfully changed. This confirmation is being sent to your previous address so you know the switch happened."
        )
      else
        dgettext(
          "emails",
          "Your Tymeslot account email address has been successfully changed."
        )
      end

    mjml_content = """
    #{Text.centered_text(Greeting.html(user), padding: "8px 0 4px 0", font_size: "16px")}

    #{Text.centered_text(intro, padding: "0 0 20px 0")}

    #{Callouts.alert_box(@intent, dgettext("emails", "Email change completed successfully."))}

    #{Cards.contact_details_card(dgettext("emails", "Change details"), [%{label: dgettext("emails", "Previous email"), value: old_email}, %{label: dgettext("emails", "New email"), value: new_email}, %{label: dgettext("emails", "Changed at"), value: format_time(confirmed_time)}, %{label: dgettext("emails", "Status"), value: dgettext("emails", "Active")}])}

    #{Text.section_title(dgettext("emails", "What you need to know"), padding: "24px 0 8px 0")}

    #{Text.bullet_list([dgettext("emails", "Use %{new_email} to sign in from now on", new_email: new_email), dgettext("emails", "All future emails will be sent to your new address"), dgettext("emails", "Your meetings and settings remain unchanged"), dgettext("emails", "You may need to sign in again on other devices")])}

    #{if is_old_email do
      Callouts.alert_box(:alert,
      dgettext("emails", "If you did not authorise this change, please contact support immediately. You will no longer receive emails at this address."),
      title: dgettext("emails", "Didn't expect this?"))
    else
      Callouts.alert_box(:confirmed,
      dgettext("emails", "For security, a copy of this confirmation was sent to your previous email address."))
    end}

    #{Text.system_footer_note(dgettext("emails", "This is a confirmation of changes made to your account. If you have any questions, please contact support."))}
    """

    TemplateHelper.compile_system_template(
      mjml_content,
      dgettext("emails", "Account Update"),
      dgettext("emails", "Your Tymeslot email address has been changed."),
      intent: @intent,
      eyebrow: dgettext("emails", "Confirmed"),
      stage_title: dgettext("emails", "Email change complete"),
      stage_subtitle: dgettext("emails", "Your account is now using the new address.")
    )
  end

  @spec render_text(
          Tymeslot.Emails.EmailService.user_map(),
          String.t(),
          String.t(),
          DateTime.t() | nil,
          boolean()
        ) :: String.t()
  def render_text(user, old_email, new_email, confirmed_time, is_old_email \\ false) do
    intro =
      if is_old_email do
        dgettext(
          "emails",
          "Your Tymeslot account email address has been successfully changed. This confirmation is being sent to your previous address so you know the switch happened."
        )
      else
        dgettext(
          "emails",
          "Your Tymeslot account email address has been successfully changed."
        )
      end

    security_notice =
      if is_old_email do
        "\n" <>
          dgettext(
            "emails",
            "If you did not authorise this change, please contact support immediately. You will no longer receive emails at this address."
          )
      else
        "\n" <>
          dgettext(
            "emails",
            "For security, a copy of this confirmation was sent to your previous email address."
          )
      end

    """
    #{dgettext("emails", "Email change complete")}

    #{Greeting.text(user)}

    #{intro}

    #{dgettext("emails", "CHANGE DETAILS:")}
    #{dgettext("emails", "Previous email:")} #{old_email}
    #{dgettext("emails", "New email:")} #{new_email}
    #{dgettext("emails", "Changed at:")} #{format_time(confirmed_time)}
    #{dgettext("emails", "Status:")} #{dgettext("emails", "Active")}

    #{dgettext("emails", "WHAT YOU NEED TO KNOW:")}
    - #{dgettext("emails", "Use %{new_email} to sign in from now on", new_email: new_email)}
    - #{dgettext("emails", "All future emails will be sent to your new address")}
    - #{dgettext("emails", "Your meetings and settings remain unchanged")}
    - #{dgettext("emails", "You may need to sign in again on other devices")}
    #{security_notice}
    """
  end

  defp format_time(nil), do: dgettext("emails", "Just now")

  defp format_time(datetime) do
    Formatting.format_datetime(datetime, Gettext.get_locale(TymeslotWeb.Gettext))
  end
end
