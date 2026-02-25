defmodule Tymeslot.LocalesTest do
  use Tymeslot.DataCase, async: false
  @moduletag :utils

  alias Tymeslot.Locales

  setup do
    existing = Application.get_env(:tymeslot, :locales)

    on_exit(fn ->
      if existing do
        Application.put_env(:tymeslot, :locales, existing)
      else
        Application.delete_env(:tymeslot, :locales)
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
end
