defmodule Tymeslot.Emails.Templates.EmailChangeConfirmed do
  @moduledoc """
  Email template for confirming a successful email change.
  Sent to BOTH the old and new email addresses after verification.
  """
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Emails.Shared.{Callouts, Cards, Sanitise, TemplateHelper, Text}

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
    safe_name = Sanitise.sanitize_for_email(user.name || new_email)
    safe_old_email = Sanitise.sanitize_for_email(old_email)
    safe_new_email = Sanitise.sanitize_for_email(new_email)

    intro =
      if is_old_email do
        dgettext(
          "emails",
          "Hi %{name}, your Tymeslot account email address has been successfully changed. This confirmation is being sent to your previous address so you know the switch happened.",
          name: safe_name
        )
      else
        dgettext(
          "emails",
          "Hi %{name}, your Tymeslot account email address has been successfully changed.",
          name: safe_name
        )
      end

    mjml_content = """
    #{Text.centered_text(intro, padding: "8px 0 20px 0")}

    #{Callouts.alert_box(@intent, dgettext("emails", "Email change completed successfully."))}

    #{Cards.contact_details_card(dgettext("emails", "Change details"), "", [%{label: dgettext("emails", "Previous email"), value: safe_old_email}, %{label: dgettext("emails", "New email"), value: safe_new_email}, %{label: dgettext("emails", "Changed at"), value: format_time(confirmed_time)}, %{label: dgettext("emails", "Status"), value: dgettext("emails", "Active")}])}

    #{Text.section_title(dgettext("emails", "What you need to know"), padding: "24px 0 8px 0")}

    #{bullet_list([dgettext("emails", "Use %{new_email} to sign in from now on", new_email: safe_new_email), dgettext("emails", "All future emails will be sent to your new address"), dgettext("emails", "Your meetings and settings remain unchanged"), dgettext("emails", "You may need to sign in again on other devices")])}

    #{if is_old_email do
      Callouts.alert_box(:alert,
      dgettext("emails", "If you did not authorise this change, please contact support immediately. You will no longer receive emails at this address."),
      title: dgettext("emails", "Didn't expect this?"))
    else
      ""
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
    name = user.name || new_email

    intro =
      if is_old_email do
        dgettext(
          "emails",
          "Hi %{name}, your Tymeslot account email address has been successfully changed. This confirmation is being sent to your previous address so you know the switch happened.",
          name: name
        )
      else
        dgettext(
          "emails",
          "Hi %{name}, your Tymeslot account email address has been successfully changed.",
          name: name
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
        ""
      end

    """
    #{dgettext("emails", "Email change complete")}

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
