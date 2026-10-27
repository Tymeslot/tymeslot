defmodule Tymeslot.Emails.Templates.AccountDeletionNotice do
  @moduledoc """
  Sent to the owner of an account they asked to delete.

  Two variants, chosen by `sign_in_url`: with a URL the deletion is scheduled
  and the owner can still sign in and restore the account before the date;
  with `nil` the account has been deleted. Both say plainly what happens to
  bookings, because guests are not told: bookings are deleted from Tymeslot,
  and calendar events and video links that already exist stay as they are.
  """
  use Gettext, backend: TymeslotWeb.Gettext

  alias Swoosh.Email
  alias Tymeslot.Emails.RecipientLocale

  alias Tymeslot.Auth.AccountDeletion.Policy
  alias Tymeslot.Emails.Shared.{Buttons, Formatting, Greeting, MjmlEmail, TemplateHelper, Text}

  @intent :alert

  @doc """
  The email, addressed and rendered in the recipient's locale.
  """
  @spec render(
          Tymeslot.Emails.EmailService.user_map(),
          DateTime.t(),
          String.t() | nil
        ) :: Email.t()
  def render(user, scheduled_at, sign_in_url) do
    RecipientLocale.with_user_locale(user, fn ->
      MjmlEmail.base_email()
      |> Email.to({user.name || user.email, user.email})
      |> Email.subject(subject(sign_in_url))
      |> Email.html_body(html_body(user, scheduled_at, sign_in_url))
      |> Email.text_body(text_body(user, scheduled_at, sign_in_url))
    end)
  end

  defp subject(nil), do: dgettext("emails_account", "Your Tymeslot account has been deleted")

  defp subject(_url),
    do: dgettext("emails_account", "Your Tymeslot account is scheduled for deletion")

  defp html_body(user, scheduled_at, sign_in_url) do
    scheduled_at = Policy.local_date(scheduled_at, user[:timezone])

    mjml_content = """
    #{Text.centered_html(Greeting.html(user), padding: "8px 0 4px 0", font_size: "16px")}

    #{Text.centered_text(summary(scheduled_at, sign_in_url), padding: "0 0 16px 0")}

    #{Text.centered_text(bookings_note(sign_in_url), padding: "0 0 20px 0")}

    #{restore_button(sign_in_url)}

    #{Text.system_footer_note(footer(sign_in_url))}
    """

    TemplateHelper.compile_system_template(
      mjml_content,
      dgettext("emails_account", "Account Deletion"),
      title(sign_in_url),
      intent: @intent,
      eyebrow: dgettext("emails_account", "Account"),
      stage_title: title(sign_in_url),
      stage_subtitle: subtitle(scheduled_at, sign_in_url)
    )
  end

  defp text_body(user, scheduled_at, sign_in_url) do
    scheduled_at = Policy.local_date(scheduled_at, user[:timezone])

    """
    #{title(sign_in_url)}

    #{Greeting.text(user)}

    #{summary(scheduled_at, sign_in_url)}

    #{bookings_note(sign_in_url)}
    #{restore_text(sign_in_url)}
    #{footer(sign_in_url)}
    """
  end

  defp title(nil), do: dgettext("emails_account", "Your account has been deleted")
  defp title(_url), do: dgettext("emails_account", "Your account is scheduled for deletion")

  defp subtitle(_at, nil), do: dgettext("emails_account", "Everything in it is gone.")
  defp subtitle(at, _url), do: dgettext("emails_account", "On %{date}.", date: date(at))

  defp summary(_at, nil) do
    dgettext(
      "emails_account",
      "As you asked, your Tymeslot account has been deleted, together with everything in it. This cannot be undone."
    )
  end

  defp summary(at, _url) do
    dgettext(
      "emails_account",
      "As you asked, your Tymeslot account is scheduled for deletion on %{date}. Until then it is frozen: your booking page is offline and nobody can book you. If you change your mind, sign in before that date and you can restore your account.",
      date: date(at)
    )
  end

  defp bookings_note(nil) do
    dgettext(
      "emails_account",
      "Your upcoming bookings have been deleted from Tymeslot. Your guests were not notified. Calendar events and video links that already exist have been left as they are. If a meeting will not take place, please contact your guests yourself."
    )
  end

  defp bookings_note(_url) do
    dgettext(
      "emails_account",
      "Your upcoming bookings will be deleted from Tymeslot with your account. Your guests will not be notified. Calendar events and video links that already exist will stay as they are. If a meeting will not take place, please contact your guests yourself."
    )
  end

  defp restore_button(nil), do: ""

  defp restore_button(url) do
    Buttons.action_button(@intent, dgettext("emails_account", "Sign in to restore"), url,
      full_width: true,
      size: :large
    )
  end

  defp restore_text(nil), do: ""

  defp restore_text(url) do
    """

    #{dgettext("emails_account", "Sign in to restore:")}
    #{url}
    """
  end

  defp footer(nil) do
    dgettext(
      "emails_account",
      "If you did not ask for this, contact whoever runs this Tymeslot service straight away."
    )
  end

  defp footer(_url) do
    dgettext(
      "emails_account",
      "If you did not ask for this, sign in now, restore your account and change your password."
    )
  end

  # Rendered inside the recipient's locale (see `RecipientLocale`).
  defp date(day), do: Formatting.format_date(day, Gettext.get_locale(TymeslotWeb.Gettext))
end
