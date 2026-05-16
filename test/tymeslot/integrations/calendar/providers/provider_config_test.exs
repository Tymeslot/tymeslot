defmodule Tymeslot.Integrations.Calendar.ProviderConfigTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.ProviderConfig

  describe "caldav_based_provider_strings/0" do
    test "returns the caldav-based provider list as strings" do
      assert ProviderConfig.caldav_based_provider_strings() == [
               "caldav",
               "radicale",
               "nextcloud",
               "zimbra",
               "mailbox_org",
               "baikal"
             ]
    end

    test "produces no duplicate strings" do
      strings = ProviderConfig.caldav_based_provider_strings()
      assert length(strings) == length(Enum.uniq(strings))
    end

    test "all elements are binaries (database string shape)" do
      assert Enum.all?(ProviderConfig.caldav_based_provider_strings(), &is_binary/1)
    end
  end

  describe "locked_url_for/1" do
    test "atom key returns a map with :url and :tooltip for a locked provider" do
      result = ProviderConfig.locked_url_for(:mailbox_org)
      assert is_map(result)
      assert Map.has_key?(result, :url)
      assert Map.has_key?(result, :tooltip)
      assert result.url == "https://dav.mailbox.org"
    end

    test "string key returns the same map as the atom key" do
      assert ProviderConfig.locked_url_for("mailbox_org") ==
               ProviderConfig.locked_url_for(:mailbox_org)
    end

    test "atom key for a provider without a locked URL returns nil" do
      assert ProviderConfig.locked_url_for(:caldav) == nil
    end

    test "string key for an unknown provider returns nil" do
      assert ProviderConfig.locked_url_for("unknown") == nil
    end

    test "nil returns nil" do
      assert ProviderConfig.locked_url_for(nil) == nil
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
