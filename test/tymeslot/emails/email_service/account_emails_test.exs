defmodule Tymeslot.Emails.EmailService.AccountEmailsTest do
  @moduledoc """
  Account mail renders in the recipient's stored locale, subject included.

  These emails are sent from an Oban worker, in a process that carries no
  Gettext locale. Before `Tymeslot.Emails.RecipientLocale` existed they all
  resolved against the default locale, so a German user changing their address
  received English mail no matter what `users.locale` said.
  """
  use Tymeslot.DataCase, async: false
  @moduletag :emails

  alias Tymeslot.Emails.EmailService.{AccountEmails, AuthEmails}

  import Swoosh.TestAssertions
  import Tymeslot.EmailTestHelpers

  # Delivery runs inside the CircuitBreaker GenServer, so Swoosh's test adapter
  # would otherwise post {:email, _} to that process rather than to this one.
  # Global mode routes it here instead; it requires `async: false`.
  setup :set_swoosh_global

  defp german_user(overrides) do
    build_user_data(Map.merge(%{name: "Anja Bauer", email: "anja@example.com"}, overrides))
  end

  describe "send_email_change_notification/2 in German" do
    test "renders subject and body in the recipient's locale" do
      user = german_user(%{locale: "de"})

      AccountEmails.send_email_change_notification(user, "anja.neu@example.com")

      assert_receive {:email, email}, 1000
      assert email.subject == "⚠️ Anfrage zur E-Mail-Änderung – Sicherheitswarnung"
      assert email.text_body =~ "ANFRAGEDETAILS:"
    end

    test "renders the request timestamp on a 24-hour clock, with a German month" do
      user = german_user(%{locale: "de"})

      AccountEmails.send_email_change_notification(user, "anja.neu@example.com")

      assert_receive {:email, email}, 1000
      # "Requested at" is a `DateTime.utc_now/0`, so assert on shape not value:
      # a 24-hour clock and no English meridiem is what distinguishes de from en.
      refute email.text_body =~ ~r/\d{2}:\d{2} (AM|PM)/
    end
  end

  describe "send_email_change_notification/2 with no stored locale" do
    test "falls back to English" do
      user = german_user(%{locale: nil})

      AccountEmails.send_email_change_notification(user, "anja.neu@example.com")

      assert_receive {:email, email}, 1000
      assert email.subject == "⚠️ Email Change Request - Security Alert"
    end
  end

  describe "send_email_change_confirmations/3" do
    test "sends both mails in the recipient's locale, to the right addresses" do
      user = german_user(%{locale: "de", email: "anja.neu@example.com"})

      AccountEmails.send_email_change_confirmations(
        user,
        "anja.alt@example.com",
        "anja.neu@example.com"
      )

      assert_receive {:email, old_mail}, 1000
      assert_receive {:email, new_mail}, 1000

      assert old_mail.to == [{"Anja Bauer", "anja.alt@example.com"}]
      assert old_mail.subject == "E-Mail-Adresse geändert – Tymeslot-Konto"

      assert new_mail.to == [{"Anja Bauer", "anja.neu@example.com"}]
      assert new_mail.subject == "E-Mail-Adresse erfolgreich geändert"
    end
  end

  describe "send_email_change_verification/3" do
    test "renders the subject in the recipient's locale" do
      user = german_user(%{locale: "de"})

      AccountEmails.send_email_change_verification(user, "anja.neu@example.com", "https://x/y")

      assert_receive {:email, email}, 1000
      assert email.subject == "Bestätigen Sie Ihre neue E-Mail-Adresse"
    end
  end

  describe "auth emails" do
    test "password reset renders in the recipient's locale" do
      user = german_user(%{locale: "de"})

      AuthEmails.send_password_reset(user, "https://x/reset")

      assert_receive {:email, email}, 1000
      assert email.subject == "Passwort zurücksetzen"
    end

    test "email verification renders in the recipient's locale" do
      user = german_user(%{locale: "de"})

      AuthEmails.send_email_verification(user, "https://x/verify")

      assert_receive {:email, email}, 1000
      assert email.subject == "Bestätigen Sie Ihre E-Mail-Adresse"
    end

    test "email verification falls back to English without a stored locale" do
      user = german_user(%{locale: nil})

      AuthEmails.send_email_verification(user, "https://x/verify")

      assert_receive {:email, email}, 1000
      assert email.subject == "Verify your email address"
    end
  end
end
