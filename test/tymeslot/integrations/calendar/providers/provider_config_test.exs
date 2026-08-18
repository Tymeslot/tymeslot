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
               "apple",
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

      assert result == %{
               url: "https://dav.mailbox.org",
               tooltip:
                 "mailbox.org always uses this CalDAV server — the address cannot be changed"
             }
    end

    test "string key returns the same map as the atom key" do
      assert ProviderConfig.locked_url_for("mailbox_org") ==
               ProviderConfig.locked_url_for(:mailbox_org)
    end

    test "Apple iCloud has a locked CalDAV URL" do
      assert %{url: "https://caldav.icloud.com"} = ProviderConfig.locked_url_for(:apple)
      assert ProviderConfig.caldav_based?(:apple)
      assert ProviderConfig.display_name(:apple) == "Apple iCloud"
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

  describe "parse/1" do
    test "accepts a valid provider atom" do
      assert ProviderConfig.parse(:caldav) == {:ok, :caldav}
    end

    test "accepts a valid provider string" do
      assert ProviderConfig.parse("google") == {:ok, :google}
    end

    test "rejects an atom that is known to the VM but not a valid provider" do
      assert ProviderConfig.parse(:totally_unknown_atom) == {:error, :unknown}
    end

    test "rejects a string whose atom has never been created (truly unknown)" do
      assert ProviderConfig.parse("totally_unknown_string_xyzzy") == {:error, :unknown}
    end

    test "rejects a non-string, non-atom value" do
      assert ProviderConfig.parse(42) == {:error, :unknown}
    end

    test "accepts all enabled provider atoms" do
      for provider <- ProviderConfig.all_providers() do
        assert ProviderConfig.parse(provider) == {:ok, provider}
      end
    end

    test "accepts all enabled provider strings" do
      for provider <- ProviderConfig.all_providers() do
        assert ProviderConfig.parse(Atom.to_string(provider)) == {:ok, provider}
      end
    end

    test "rejects providers that are statically known but disabled via toggle" do
      # :demo is in @providers but pinned off via test config; parse/1 must
      # refuse to surface it because it gates user-input setup flows.
      assert ProviderConfig.parse(:demo) == {:error, :unknown}
      assert ProviderConfig.parse("demo") == {:error, :unknown}
    end
  end

  describe "parse_known/1" do
    test "accepts a valid provider atom" do
      assert ProviderConfig.parse_known(:caldav) == {:ok, :caldav}
    end

    test "accepts a valid provider string" do
      assert ProviderConfig.parse_known("google") == {:ok, :google}
    end

    test "accepts dev-only providers regardless of toggle (e.g. :debug)" do
      assert ProviderConfig.parse_known(:debug) == {:ok, :debug}
      assert ProviderConfig.parse_known("debug") == {:ok, :debug}
    end

    test "accepts providers that may be disabled via config but are statically known" do
      # `:demo` is disabled in the test environment but is part of @providers,
      # so parse_known/1 must still return {:ok, :demo} — this is the whole
      # point of the toggle-agnostic variant.
      assert ProviderConfig.parse_known(:demo) == {:ok, :demo}
      assert ProviderConfig.parse_known("demo") == {:ok, :demo}
    end

    test "rejects an atom that is not a known provider" do
      assert ProviderConfig.parse_known(:totally_unknown_atom) == {:error, :unknown}
    end

    test "rejects a string whose atom has never been created" do
      assert ProviderConfig.parse_known("totally_unknown_string_xyzzy") == {:error, :unknown}
    end

    test "rejects a non-string, non-atom value" do
      assert ProviderConfig.parse_known(42) == {:error, :unknown}
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

    test "excludes ics_url: a provider-global breaker is the wrong shape for arbitrary per-user feed hosts" do
      breakers = ProviderConfig.providers_with_circuit_breakers()

      refute :ics_url in breakers
    end

    test "stays in sync with metadata's circuit_breaker_enabled flag" do
      breakers = ProviderConfig.providers_with_circuit_breakers()

      Enum.each(breakers, fn p ->
        assert ProviderConfig.circuit_breaker_enabled?(p),
               "#{inspect(p)} listed but its metadata disables circuit breakers"
      end)
    end

    test "omits no provider whose metadata enables circuit breakers" do
      breakers = ProviderConfig.providers_with_circuit_breakers()

      # Walking the list itself can only show that nothing extra is in it. The
      # direction that matters is the other one: a provider that should be
      # monitored and silently isn't. The candidates come from the static
      # constraint list, which no runtime toggle can shorten.
      wanted =
        ProviderConfig.provider_constraint_list()
        |> Enum.map(fn name ->
          {:ok, provider} = ProviderConfig.parse_known(name)
          provider
        end)
        |> Enum.filter(&ProviderConfig.circuit_breaker_enabled?/1)

      Enum.each(wanted, fn p ->
        assert p in breakers,
               "#{inspect(p)} enables circuit breakers in its metadata but is not listed"
      end)
    end
  end
end
