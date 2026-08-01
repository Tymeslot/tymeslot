defmodule Tymeslot.LocalesTest do
  use Tymeslot.DataCase, async: false
  @moduletag :utils

  alias Tymeslot.Locales

  setup do
    existing = Application.get_env(:tymeslot, :locales)
    existing_pseudo = Application.get_env(:tymeslot, :pseudo_locale_enabled)

    on_exit(fn ->
      if existing do
        Application.put_env(:tymeslot, :locales, existing)
      else
        Application.delete_env(:tymeslot, :locales)
      end

      if is_nil(existing_pseudo) do
        Application.delete_env(:tymeslot, :pseudo_locale_enabled)
      else
        Application.put_env(:tymeslot, :pseudo_locale_enabled, existing_pseudo)
      end
    end)

    :ok
  end

  describe "default_locale/0" do
    test "returns configured default locale" do
      Application.put_env(:tymeslot, :locales, default: "de", supported: [])
      assert Locales.default_locale() == "de"
    end

    test "falls back to 'en' when config key is absent" do
      Application.delete_env(:tymeslot, :locales)
      assert Locales.default_locale() == "en"
    end

    test "falls back to 'en' when default key is missing from locales config" do
      Application.put_env(:tymeslot, :locales, supported: [])
      assert Locales.default_locale() == "en"
    end
  end

  describe "supported_codes/0" do
    test "returns list of locale codes from config" do
      Application.put_env(:tymeslot, :locales,
        supported: [%{code: "en"}, %{code: "de"}, %{code: "fr"}]
      )

      assert Locales.supported_codes() == ["en", "de", "fr"]
    end

    test "returns empty list when config key is absent" do
      Application.delete_env(:tymeslot, :locales)
      assert Locales.supported_codes() == []
    end

    test "returns empty list when supported key is missing from locales config" do
      Application.put_env(:tymeslot, :locales, default: "en")
      assert Locales.supported_codes() == []
    end
  end

  describe "supported/0" do
    test "returns metadata for every supported locale, well-formed" do
      locales = Locales.supported()

      # Derived from config so adding a locale never requires editing this test.
      refute locales == []

      # The default locale must itself be offered, or the language picker can
      # never render the locale the app falls back to.
      assert Locales.default_locale() in Enum.map(locales, & &1.code)

      Enum.each(locales, fn locale ->
        # Each entry carries exactly the three keys callers read: an ISO 639-1
        # language code, the locale's own endonym, and the ISO 3166-1 alpha-3
        # country code the flag is picked from.
        assert Enum.sort(Map.keys(locale)) == [:code, :country_code, :name]
        assert locale.code =~ ~r/^[a-z]{2}$/
        assert String.trim(locale.name) != ""
        assert Atom.to_string(locale.country_code) =~ ~r/^[a-z]{3}$/
      end)
    end

    test "includes English metadata" do
      english = Enum.find(Locales.supported(), &(&1.code == "en"))

      assert english.name == "English"
      assert english.country_code == :gbr
    end

    test "includes German metadata" do
      german = Enum.find(Locales.supported(), &(&1.code == "de"))

      assert german.name == "Deutsch"
      assert german.country_code == :deu
    end

    test "supported_codes/0 is derived from supported/0" do
      assert Locales.supported_codes() == Enum.map(Locales.supported(), & &1.code)
    end
  end

  describe "acceptable?/1" do
    setup do
      Application.put_env(:tymeslot, :locales, supported: [%{code: "en"}, %{code: "de"}])

      :ok
    end

    test "accepts supported locale codes" do
      assert Locales.acceptable?("en")
      assert Locales.acceptable?("de")
    end

    test "rejects unknown locale codes" do
      refute Locales.acceptable?("zz")
    end

    test "rejects non-string input" do
      refute Locales.acceptable?(nil)
      refute Locales.acceptable?(:de)
    end

    test "accepts the pseudo locale only when pseudo-localisation is enabled" do
      Application.put_env(:tymeslot, :pseudo_locale_enabled, false)
      refute Locales.acceptable?("pseudo")

      Application.put_env(:tymeslot, :pseudo_locale_enabled, true)
      assert Locales.acceptable?("pseudo")
    end

    test "the pseudo locale is never a supported locale" do
      Application.put_env(:tymeslot, :pseudo_locale_enabled, true)
      refute Locales.pseudo_locale() in Locales.supported_codes()
    end
  end

  describe "pseudo_enabled?/0" do
    test "reflects the configuration flag" do
      Application.put_env(:tymeslot, :pseudo_locale_enabled, true)
      assert Locales.pseudo_enabled?()

      Application.put_env(:tymeslot, :pseudo_locale_enabled, false)
      refute Locales.pseudo_enabled?()
    end

    test "defaults to false when the flag is absent" do
      Application.delete_env(:tymeslot, :pseudo_locale_enabled)
      refute Locales.pseudo_enabled?()
    end
  end
end
