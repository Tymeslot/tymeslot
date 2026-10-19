defmodule Tymeslot.Emails.Templates.EmailChangeConfirmed do
  @moduledoc """
  Email template for confirming a successful email change.
  Sent to BOTH the old and new email addresses after verification.
  """
  use Gettext, backend: TymeslotWeb.Gettext

  alias Swoosh.Email
  alias Tymeslot.Emails.{HostClock, RecipientLocale}
  alias Tymeslot.Emails.Shared.{Callouts, Cards, Greeting, MjmlEmail, TemplateHelper, Text}

  # A positive confirmation that an account change succeeded.
  @intent :confirmed

  @doc """
  The confirmation for one of the two addresses, rendered in the user's
  locale: `:old` tells the previous address that the switch happened, `:new`
  welcomes the new one. The role picks both the recipient and the wording.
  """
  @spec render(
          :old | :new,
          Tymeslot.Emails.EmailService.user_map(),
          String.t(),
          String.t(),
          DateTime.t() | nil
        ) :: Email.t()
  def render(role, user, old_email, new_email, confirmed_time) when role in [:old, :new] do
    RecipientLocale.with_user_locale(user, fn ->
      {recipient, subject} = recipient_and_subject(role, old_email, new_email)
      change = change(role, user, old_email, new_email, confirmed_time)

      MjmlEmail.base_email()
      |> Email.to({user.name || recipient, recipient})
      |> Email.subject(subject)
      |> Email.html_body(html_body(user, change))
      |> Email.text_body(text_body(user, change))
    end)
  end

  defp recipient_and_subject(:old, old_email, _new_email),
    do: {old_email, dgettext("emails_account", "Email Address Changed - Tymeslot Account")}

  defp recipient_and_subject(:new, _old_email, new_email),
    do: {new_email, dgettext("emails_account", "Email Address Changed Successfully")}

  # What both parts of the email say, worded once for the recipient's role.
  defp change(role, user, old_email, new_email, confirmed_time) do
    %{
      role: role,
      old_email: old_email,
      new_email: new_email,
      changed_at: format_time(confirmed_time, user),
      intro: intro(role),
      notes: [
        dgettext("emails_account", "Use %{new_email} to sign in from now on",
          new_email: new_email
        ),
        dgettext("emails_account", "All future emails will be sent to your new address"),
        dgettext("emails_account", "Your meetings and settings remain unchanged"),
        dgettext("emails_account", "You may need to sign in again on other devices")
      ],
      security_notice: security_notice(role)
    }
  end

  defp intro(:old),
    do:
      dgettext(
        "emails_account",
        "Your Tymeslot account email address has been successfully changed. This confirmation is being sent to your previous address so you know the switch happened."
      )

  defp intro(:new),
    do:
      dgettext(
        "emails_account",
        "Your Tymeslot account email address has been successfully changed."
      )

  defp security_notice(:old),
    do:
      dgettext(
        "emails_account",
        "If you did not authorise this change, please contact support immediately. You will no longer receive emails at this address."
      )

  defp security_notice(:new),
    do:
      dgettext(
        "emails_account",
        "For security, a copy of this confirmation was sent to your previous email address."
      )

  defp html_body(user, change) do
    mjml_content = """
    #{Text.centered_html(Greeting.html(user), padding: "8px 0 4px 0", font_size: "16px")}

    #{Text.centered_text(change.intro, padding: "0 0 20px 0")}

    #{Callouts.alert_box(@intent, dgettext("emails_account", "Email change completed successfully."))}

    #{Cards.contact_details_card(dgettext("emails_account", "Change details"), [%{label: dgettext("emails_account", "Previous email"), value: change.old_email}, %{label: dgettext("emails_account", "New email"), value: change.new_email}, %{label: dgettext("emails_account", "Changed at"), value: change.changed_at}, %{label: dgettext("emails_account", "Status"), value: dgettext("emails_account", "Active")}])}

    #{Text.section_title(dgettext("emails_account", "What you need to know"), padding: "24px 0 8px 0")}

    #{Text.bullet_list(change.notes)}

    #{security_callout(change)}

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

  defp security_callout(%{role: :old, security_notice: notice}),
    do:
      Callouts.alert_box(:alert, notice, title: dgettext("emails_account", "Didn't expect this?"))

  defp security_callout(%{role: :new, security_notice: notice}),
    do: Callouts.alert_box(:confirmed, notice)

  defp text_body(user, change) do
    """
    #{dgettext("emails_account", "Email change complete")}

    #{Greeting.text(user)}

    #{change.intro}

    #{dgettext("emails_account", "CHANGE DETAILS:")}
    #{dgettext("emails_account", "Previous email:")} #{change.old_email}
    #{dgettext("emails_account", "New email:")} #{change.new_email}
    #{dgettext("emails_account", "Changed at:")} #{change.changed_at}
    #{dgettext("emails_account", "Status:")} #{dgettext("emails_account", "Active")}

    #{dgettext("emails_account", "WHAT YOU NEED TO KNOW:")}
    #{Enum.map_join(change.notes, "\n", &"- #{&1}")}

    #{change.security_notice}
    """
  end

  defp format_time(nil, _user), do: dgettext("emails_account", "Just now")

  # A security notice is easier to act on in the user's own zone and clock.
  defp format_time(datetime, user),
    do: HostClock.format_datetime(datetime, user.id, Gettext.get_locale(TymeslotWeb.Gettext))
end
