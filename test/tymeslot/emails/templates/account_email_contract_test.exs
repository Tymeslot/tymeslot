defmodule Tymeslot.Emails.Templates.AccountEmailContractTest do
  @moduledoc """
  Every account email template returns the complete email: addressed,
  subject set, both parts rendered, all in the recipient's own locale.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :emails
  @moduletag :auth

  alias Tymeslot.Emails.Templates.{
    AccountDeletionNotice,
    EmailChangeConfirmed,
    EmailChangeNotification,
    EmailChangeVerification,
    EmailVerification,
    NoPasswordToReset,
    PasswordReset,
    SignupAttemptNotice,
    SocialSignupConfirmation
  }

  @url "https://example.com/link"
  @at ~U[2026-10-17 09:00:00Z]

  defp user(locale),
    do: %{id: nil, email: "ada@example.com", name: "Ada", locale: locale, provider: "google"}

  # {template call, recipient address, English subject, German subject}
  defp cases do
    [
      {&EmailVerification.render(&1, @url), "ada@example.com", "Verify your email address",
       "Bestätigen Sie Ihre E-Mail-Adresse"},
      {&PasswordReset.render(&1, @url), "ada@example.com", "Reset your password",
       "Passwort zurücksetzen"},
      {&NoPasswordToReset.render(&1, @url), "ada@example.com",
       "Your Tymeslot account has no password", "Ihr Tymeslot-Konto hat kein Passwort"},
      {&SignupAttemptNotice.render(&1, @url, @url), "ada@example.com",
       "You already have a Tymeslot account", "Sie haben bereits ein Tymeslot-Konto"},
      {&AccountDeletionNotice.render(&1, @at, @url), "ada@example.com",
       "Your Tymeslot account is scheduled for deletion",
       "Ihr Tymeslot-Konto ist zur Löschung vorgemerkt"},
      {&AccountDeletionNotice.render(&1, @at, nil), "ada@example.com",
       "Your Tymeslot account has been deleted", "Ihr Tymeslot-Konto wurde gelöscht"},
      {&SocialSignupConfirmation.render(&1, "github", @url), "ada@example.com",
       "Confirm your email to finish signing up",
       "Bestätigen Sie Ihre E-Mail-Adresse, um die Registrierung abzuschließen"},
      {&EmailChangeVerification.render(&1, "new@example.com", @url), "new@example.com",
       "Verify your new email address", "Bestätigen Sie Ihre neue E-Mail-Adresse"},
      {&EmailChangeNotification.render(&1, "new@example.com", @at), "ada@example.com",
       "⚠️ Email Change Request - Security Alert",
       "⚠️ Anfrage zur E-Mail-Änderung – Sicherheitswarnung"},
      {&EmailChangeConfirmed.render(:old, &1, "ada@example.com", "new@example.com", @at),
       "ada@example.com", "Email Address Changed - Tymeslot Account",
       "E-Mail-Adresse geändert – Tymeslot-Konto"},
      {&EmailChangeConfirmed.render(:new, &1, "ada@example.com", "new@example.com", @at),
       "new@example.com", "Email Address Changed Successfully",
       "E-Mail-Adresse erfolgreich geändert"}
    ]
  end

  test "each template addresses the email and sets its subject and both parts" do
    for {render, to, subject, _de} <- cases() do
      email = render.(user("en"))

      assert email.to == [{"Ada", to}], subject
      assert email.subject == subject
      assert email.html_body =~ "<html"
      assert email.text_body =~ "Ada"
    end
  end

  test "each template renders subject and body in the recipient's locale" do
    for {render, _to, subject, de_subject} <- cases() do
      english = render.(user("en"))
      german = render.(user("de"))

      assert german.subject == de_subject, subject
      refute german.text_body == english.text_body
      refute german.html_body == english.html_body
    end
  end
end
