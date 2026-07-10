defmodule Tymeslot.Emails.RecipientLocaleTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Auth.UserQueries
  alias Tymeslot.Emails.RecipientLocale

  import Tymeslot.TestFixtures

  describe "locale_for/1" do
    test "uses the user's stored locale" do
      assert RecipientLocale.locale_for(%{locale: "de"}) == "de"
    end

    test "falls back to the default when the user has made no choice" do
      assert RecipientLocale.locale_for(%{locale: nil}) == "en"
    end

    test "falls back to the default for a map with no locale key at all" do
      assert RecipientLocale.locale_for(%{email: "a@b.com"}) == "en"
    end

    test "falls back to the default for an unsupported locale code" do
      assert RecipientLocale.locale_for(%{locale: "xx"}) == "en"
    end
  end

  describe "locale_for_user_id/1" do
    test "loads the locale from the user row" do
      user = create_user_fixture()
      {:ok, user} = UserQueries.update_user_locale(user, "de")

      assert RecipientLocale.locale_for_user_id(user.id) == "de"
    end

    test "defaults when the user has no stored locale" do
      user = create_user_fixture()

      assert RecipientLocale.locale_for_user_id(user.id) == "en"
    end

    test "defaults for a nil id rather than raising" do
      assert RecipientLocale.locale_for_user_id(nil) == "en"
    end

    test "defaults for an id that no longer exists" do
      assert RecipientLocale.locale_for_user_id(-1) == "en"
    end
  end

  describe "with_user_locale/2" do
    test "establishes the locale for the duration of the function" do
      assert RecipientLocale.with_user_locale(%{locale: "de"}, fn ->
               Gettext.get_locale(TymeslotWeb.Gettext)
             end) == "de"
    end

    test "restores the previous locale afterwards" do
      Gettext.put_locale(TymeslotWeb.Gettext, "en")
      RecipientLocale.with_user_locale(%{locale: "de"}, fn -> :ok end)

      assert Gettext.get_locale(TymeslotWeb.Gettext) == "en"
    end

    test "translates through the Core backend inside the block" do
      translated =
        RecipientLocale.with_user_locale(%{locale: "de"}, fn ->
          Gettext.dgettext(TymeslotWeb.Gettext, "emails", "Verify your email address")
        end)

      assert translated == "Bestätigen Sie Ihre E-Mail-Adresse"
    end
  end
end
