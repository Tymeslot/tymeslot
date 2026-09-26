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
          "emails_account",
          "Your Tymeslot account email address has been successfully changed. This confirmation is being sent to your previous address so you know the switch happened."
        )
      else
        dgettext(
          "emails_account",
          "Your Tymeslot account email address has been successfully changed."
        )
      end

    mjml_content = """
    #{Text.centered_html(Greeting.html(user), padding: "8px 0 4px 0", font_size: "16px")}

    #{Text.centered_text(intro, padding: "0 0 20px 0")}

    #{Callouts.alert_box(@intent, dgettext("emails_account", "Email change completed successfully."))}

    #{Cards.contact_details_card(dgettext("emails_account", "Change details"), [%{label: dgettext("emails_account", "Previous email"), value: old_email}, %{label: dgettext("emails_account", "New email"), value: new_email}, %{label: dgettext("emails_account", "Changed at"), value: format_time(confirmed_time)}, %{label: dgettext("emails_account", "Status"), value: dgettext("emails_account", "Active")}])}

    #{Text.section_title(dgettext("emails_account", "What you need to know"), padding: "24px 0 8px 0")}

    #{Text.bullet_list([dgettext("emails_account", "Use %{new_email} to sign in from now on", new_email: new_email), dgettext("emails_account", "All future emails will be sent to your new address"), dgettext("emails_account", "Your meetings and settings remain unchanged"), dgettext("emails_account", "You may need to sign in again on other devices")])}

    #{if is_old_email do
      Callouts.alert_box(:alert,
      dgettext("emails_account", "If you did not authorise this change, please contact support immediately. You will no longer receive emails at this address."),
      title: dgettext("emails_account", "Didn't expect this?"))
    else
      Callouts.alert_box(:confirmed,
      dgettext("emails_account", "For security, a copy of this confirmation was sent to your previous email address."))
    end}

    #{Text.system_footer_note(dgettext("emails_account", "This is a confirmation of changes made to your account. If you have any questions, please contact support."))}
    """

    TemplateHelper.compile_system_template(
      mjml_content,
      dgettext("emails_account", "Account Update"),
      dgettext("emails_account", "Your Tymeslot email address has been changed."),
      intent: @intent,
      eyebrow: dgettext("emails_account", "Confirmed"),
      stage_title: dgettext("emails_account", "Email change complete"),
      stage_subtitle: dgettext("emails_account", "Your account is now using the new address.")
    )
  end

  @spec render_text(
          Tymeslot.Emails.EmailService.user_map(),
          String.t(),
          String.t(),
          DateTime.t() | nil,
          boolean()
        ) :: String.t()
  def render_text(user, old_email, new_email, confirmed_time, is_old_email) do
    intro =
      if is_old_email do
        dgettext(
          "emails_account",
          "Your Tymeslot account email address has been successfully changed. This confirmation is being sent to your previous address so you know the switch happened."
        )
      else
        dgettext(
          "emails_account",
          "Your Tymeslot account email address has been successfully changed."
        )
      end

    security_notice =
      if is_old_email do
        "\n" <>
          dgettext(
            "emails_account",
            "If you did not authorise this change, please contact support immediately. You will no longer receive emails at this address."
          )
      else
        "\n" <>
          dgettext(
            "emails_account",
            "For security, a copy of this confirmation was sent to your previous email address."
          )
      end

    """
    #{dgettext("emails_account", "Email change complete")}

    #{Greeting.text(user)}

    #{intro}

    #{dgettext("emails_account", "CHANGE DETAILS:")}
    #{dgettext("emails_account", "Previous email:")} #{old_email}
    #{dgettext("emails_account", "New email:")} #{new_email}
    #{dgettext("emails_account", "Changed at:")} #{format_time(confirmed_time)}
    #{dgettext("emails_account", "Status:")} #{dgettext("emails_account", "Active")}

    #{dgettext("emails_account", "WHAT YOU NEED TO KNOW:")}
    - #{dgettext("emails_account", "Use %{new_email} to sign in from now on", new_email: new_email)}
    - #{dgettext("emails_account", "All future emails will be sent to your new address")}
    - #{dgettext("emails_account", "Your meetings and settings remain unchanged")}
    - #{dgettext("emails_account", "You may need to sign in again on other devices")}
    #{security_notice}
    """
  end

  defp format_time(nil), do: dgettext("emails_account", "Just now")

  defp format_time(datetime) do
    Formatting.format_datetime(datetime, Gettext.get_locale(TymeslotWeb.Gettext))
  end
end
