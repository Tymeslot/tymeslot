defmodule Tymeslot.Emails.Shared.GreetingTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Shared.Greeting

  describe "html/1" do
    test "uses the user's name when present" do
      assert Greeting.html(%{name: "Anna"}) == "Hi Anna,"
    end

    test "falls back to a neutral greeting when name is nil" do
      assert Greeting.html(%{name: nil}) == "Hi there,"
    end

    test "falls back to a neutral greeting when name is blank" do
      assert Greeting.html(%{name: ""}) == "Hi there,"
      assert Greeting.html(%{name: "   "}) == "Hi there,"
    end

    test "falls back to a neutral greeting when the schema lacks a name field" do
      assert Greeting.html(%{}) == "Hi there,"
    end

    test "never falls back to the user's email address" do
      assert Greeting.html(%{name: nil, email: "user@example.com"}) == "Hi there,"
    end

    test "HTML-escapes the interpolated name" do
      result = Greeting.html(%{name: "<script>alert('xss')</script>"})

      refute result =~ "<script>"
      assert result =~ "&lt;script&gt;"
    end

    test "respects the recipient locale" do
      assert with_locale("de", fn -> Greeting.html(%{name: nil}) end) == "Hallo,"
      assert with_locale("fr", fn -> Greeting.html(%{name: nil}) end) == "Bonjour,"
      assert with_locale("it", fn -> Greeting.html(%{name: nil}) end) == "Ciao,"
      assert with_locale("uk", fn -> Greeting.html(%{name: nil}) end) == "Вітаю!"
    end
  end

  describe "text/1" do
    test "uses the user's name when present" do
      assert Greeting.text(%{name: "Anna"}) == "Hi Anna,"
    end

    test "falls back to a neutral greeting when name is nil" do
      assert Greeting.text(%{name: nil}) == "Hi there,"
    end

    test "falls back to a neutral greeting when name is blank" do
      assert Greeting.text(%{name: ""}) == "Hi there,"
      assert Greeting.text(%{name: "   "}) == "Hi there,"
    end

    test "never falls back to the user's email address" do
      assert Greeting.text(%{name: nil, email: "user@example.com"}) == "Hi there,"
    end

    test "respects the recipient locale" do
      assert with_locale("de", fn -> Greeting.text(%{name: nil}) end) == "Hallo,"
      assert with_locale("fr", fn -> Greeting.text(%{name: nil}) end) == "Bonjour,"
      assert with_locale("it", fn -> Greeting.text(%{name: nil}) end) == "Ciao,"
      assert with_locale("uk", fn -> Greeting.text(%{name: nil}) end) == "Вітаю!"
    end
  end

  describe "name resolution" do
    test "greets an email/password user by the name they set during onboarding" do
      # Email/password signup never writes `user.name` — the signup form has no
      # name field — so the profile is the only place the name ever lands.
      user = with_profile(build(:user, name: nil), full_name: "Ada Lovelace")

      assert Greeting.text(user) == "Hi Ada Lovelace,"
      assert Greeting.html(user) == "Hi Ada Lovelace,"
    end

    test "prefers the profile's full name over the name captured at signup" do
      user = with_profile(build(:user, name: "ada-from-github"), full_name: "Ada Lovelace")

      assert Greeting.text(user) == "Hi Ada Lovelace,"
    end

    test "falls back to the signup name before onboarding sets a full name" do
      user = with_profile(build(:user, name: "Ada from GitHub"), full_name: nil)

      assert Greeting.text(user) == "Hi Ada from GitHub,"
    end

    test "falls back to the signup name when the profile is not loaded" do
      assert Greeting.text(build(:user, name: "Ada from GitHub")) == "Hi Ada from GitHub,"
    end

    test "stays neutral when neither the profile nor the user carries a name" do
      user = with_profile(build(:user, name: nil), full_name: "   ")

      assert Greeting.text(user) == "Hi there,"
      assert Greeting.html(user) == "Hi there,"
    end

    test "never falls back to the email address once a profile is loaded" do
      user = with_profile(build(:user, name: nil, email: "ada@example.com"), full_name: nil)

      assert Greeting.text(user) == "Hi there,"
      refute Greeting.text(user) =~ "ada@example.com"
    end
  end

  defp with_profile(user, attrs) do
    %{user | profile: build(:profile, Keyword.put(attrs, :user, user))}
  end

  defp with_locale(locale, fun) do
    Gettext.with_locale(TymeslotWeb.Gettext, locale, fun)
  end
end
