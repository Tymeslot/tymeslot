defmodule Tymeslot.Emails.Templates.AccountDeletionNoticeTest do
  use ExUnit.Case, async: true

  @moduletag :emails
  @moduletag :auth

  alias Tymeslot.Emails.Templates.AccountDeletionNotice

  @recipient %{email: "ada@example.com", name: "Ada", locale: "en", id: nil}
  @at ~U[2026-10-16 09:00:00Z]

  test "a scheduled deletion names the date, offers a restore and warns about bookings" do
    Gettext.with_locale(TymeslotWeb.Gettext, "en", fn ->
      text =
        AccountDeletionNotice.render(@recipient, @at, "https://example.com/auth/login").text_body

      html =
        AccountDeletionNotice.render(@recipient, @at, "https://example.com/auth/login").html_body

      assert text =~ "scheduled for deletion on 16 October 2026"
      assert text =~ "sign in before that date and you can restore your account"
      assert text =~ "upcoming bookings will be deleted from Tymeslot"
      assert text =~ "Your guests will not be notified"
      assert text =~ "Calendar events and video links that already exist will stay as they are"
      assert text =~ "contact your guests yourself"
      assert text =~ "https://example.com/auth/login"
      assert html =~ "Sign in to restore"
    end)
  end

  test "the date is the recipient's own calendar day, not the UTC one" do
    recipient = Map.put(@recipient, :timezone, "Pacific/Kiritimati")
    at = ~U[2026-10-16 12:00:00Z]

    Gettext.with_locale(TymeslotWeb.Gettext, "en", fn ->
      text =
        AccountDeletionNotice.render(recipient, at, "https://example.com/auth/login").text_body

      html =
        AccountDeletionNotice.render(recipient, at, "https://example.com/auth/login").html_body

      assert text =~ "scheduled for deletion on 17 October 2026"
      assert html =~ "17 October 2026"
      refute html =~ "16 October 2026"
    end)
  end

  test "a German recipient gets the notice in German, with the date in German form" do
    recipient = %{@recipient | locale: "de"}

    Gettext.with_locale(TymeslotWeb.Gettext, "de", fn ->
      text =
        AccountDeletionNotice.render(recipient, @at, "https://example.com/auth/login").text_body

      html =
        AccountDeletionNotice.render(recipient, @at, "https://example.com/auth/login").html_body

      assert text =~ "Ihr Tymeslot-Konto am 16. Oktober 2026 gelöscht"
      assert text =~ "Ihre Gäste werden nicht benachrichtigt"
      assert html =~ "Am 16. Oktober 2026."
      assert html =~ "Zum Wiederherstellen anmelden"
      refute text =~ "%{date}"
      refute text =~ "October"
    end)
  end

  test "an immediate deletion says it is done, in the past tense, and offers no restore" do
    Gettext.with_locale(TymeslotWeb.Gettext, "en", fn ->
      text = AccountDeletionNotice.render(@recipient, @at, nil).text_body
      html = AccountDeletionNotice.render(@recipient, @at, nil).html_body

      assert text =~ "has been deleted"
      assert text =~ "This cannot be undone"
      assert text =~ "upcoming bookings have been deleted from Tymeslot"
      assert text =~ "Your guests were not notified"
      assert text =~ "have been left as they are"
      assert text =~ "contact your guests yourself"
      refute text =~ "Sign in to restore"
      refute html =~ "Sign in to restore"
    end)
  end
end
