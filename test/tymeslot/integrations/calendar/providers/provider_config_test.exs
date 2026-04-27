defmodule Tymeslot.Integrations.Calendar.ProviderConfigTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.ProviderConfig

  describe "caldav_based_provider_strings/0" do
    test "returns the caldav-based provider list as strings" do
      atoms = ProviderConfig.caldav_based_providers()
      strings = ProviderConfig.caldav_based_provider_strings()

      assert strings == Enum.map(atoms, &Atom.to_string/1)
    end

    test "matches the database string shape used by integration.provider" do
      strings = ProviderConfig.caldav_based_provider_strings()

      assert Enum.all?(strings, &is_binary/1)
      assert "caldav" in strings
      assert "radicale" in strings
      assert "nextcloud" in strings
      assert "zimbra" in strings
    end
  end

  describe "providers_with_circuit_breakers/0" do
    test "includes every CalDAV-based and OAuth provider" do
      breakers = ProviderConfig.providers_with_circuit_breakers()

      Enum.each(ProviderConfig.caldav_based_providers(), fn p ->
        assert p in breakers, "expected CalDAV provider #{inspect(p)} to have a breaker"
      end)

      Enum.each(ProviderConfig.oauth_providers(), fn p ->
        assert p in breakers, "expected OAuth provider #{inspect(p)} to have a breaker"
      end)
    end

    test "excludes providers whose metadata disables circuit breakers" do
      breakers = ProviderConfig.providers_with_circuit_breakers()

      refute :demo in breakers
    end

    test "stays in sync with metadata's circuit_breaker_enabled flag" do
      breakers = ProviderConfig.providers_with_circuit_breakers()

      Enum.each(breakers, fn p ->
        assert ProviderConfig.circuit_breaker_enabled?(p),
               "#{inspect(p)} listed but its metadata disables circuit breakers"
      end)
    end
  end
end
