defmodule TymeslotWeb.GettextPseudoTest do
  use ExUnit.Case, async: false
  @moduletag :utils

  alias TymeslotWeb.Gettext, as: Backend

  setup do
    original = Application.get_env(:tymeslot, :pseudo_locale_enabled)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:tymeslot, :pseudo_locale_enabled)
      else
        Application.put_env(:tymeslot, :pseudo_locale_enabled, original)
      end

      Gettext.put_locale(Backend, "en")
    end)

    :ok
  end

  describe "pseudo locale enabled" do
    setup do
      Application.put_env(:tymeslot, :pseudo_locale_enabled, true)
      Gettext.put_locale(Backend, "pseudo")
      :ok
    end

    test "wraps a plain-English msgid in coverage markers" do
      result = Gettext.dgettext(Backend, "dashboard", "Save")

      assert result =~ "⟦"
      assert result =~ "⟧"
    end

    test "resolves the real English for key-based catalogs, then pseudo-ises it" do
      # The booking domain uses semantic keys as msgids ("meeting_confirmed").
      # Pseudo must render the *English* the user sees, not the developer key.
      result = Gettext.dgettext(Backend, "booking", "meeting_confirmed")

      assert result =~ "⟦"
      # English "Meeting Confirmed!" — carries the "!", never the key's "_".
      assert result =~ "!"
      refute result =~ "_"
    end

    test "handles plural forms" do
      one =
        Gettext.dngettext(Backend, "booking", "1 slot available", "%{count} slots available", 1)

      many =
        Gettext.dngettext(Backend, "booking", "1 slot available", "%{count} slots available", 3)

      assert one =~ "⟦"
      assert one =~ "1"
      assert many =~ "3"
    end
  end

  describe "real locales are unaffected" do
    setup do
      Application.put_env(:tymeslot, :pseudo_locale_enabled, true)
      :ok
    end

    test "German renders the real translation without markers" do
      Gettext.put_locale(Backend, "de")
      result = Gettext.dgettext(Backend, "booking", "meeting_confirmed")

      assert result == "Termin bestätigt!"
      refute result =~ "⟦"
    end

    test "English renders the real translation without markers" do
      Gettext.put_locale(Backend, "en")
      result = Gettext.dgettext(Backend, "booking", "meeting_confirmed")

      assert result == "Meeting Confirmed!"
      refute result =~ "⟦"
    end
  end

  describe "pseudo locale disabled" do
    test "does not transform even when the pseudo locale is set" do
      Application.put_env(:tymeslot, :pseudo_locale_enabled, false)
      Gettext.put_locale(Backend, "pseudo")

      result = Gettext.dgettext(Backend, "dashboard", "Save")

      refute result =~ "⟦"
      assert result == "Save"
    end
  end
end
