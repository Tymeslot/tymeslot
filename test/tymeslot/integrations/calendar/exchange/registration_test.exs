defmodule Tymeslot.Integrations.Calendar.Exchange.RegistrationTest do
  @moduledoc """
  Covers the parts of registering Exchange that are reachability rather than
  metadata: the registry lookup every persisted integration goes through, and
  the circuit breaker every provider call is wrapped in.

  Both are derived from `ProviderConfig`, and both fail quietly when the
  derivation misses a provider — the registry answers a plain `{:error,
  binary}` that reads like a typo, and the breaker answers
  `{:error, {:invalid_provider, _}}` from a guard rather than raising — so
  neither is observable from `ProviderConfig`'s own tests.
  """

  use ExUnit.Case, async: false

  @moduletag :integrations
  @moduletag :calendar

  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Integrations.Calendar.Exchange.Provider
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.Providers.ProviderRegistry

  setup do
    CalendarCircuitBreaker.reset(:exchange)
    :ok
  end

  describe "the connection UI pairing" do
    test "setup_component/0 names a module that exists" do
      # A bare module reference as a value produces no compile warning, so a
      # rename on either side would hand the LiveView a missing module at
      # runtime rather than failing the build.
      assert Code.ensure_loaded?(Provider.setup_component())
    end

    test "the picker's form gate admits exchange" do
      # Without this the Connect button falls through to the catch-all and
      # flashes "Unsupported provider": the provider renders a card that
      # cannot be used.
      assert "exchange" in ProviderConfig.ews_provider_strings()

      form_providers =
        ProviderConfig.caldav_based_provider_strings() ++
          ProviderConfig.subscription_provider_strings() ++
          ProviderConfig.ews_provider_strings()

      assert "exchange" in form_providers
    end

    test "is enabled, so the card renders at all" do
      assert ProviderConfig.provider_enabled?(:exchange)
    end
  end

  describe "the registry" do
    test "resolves exchange from both the atom and the stored string" do
      assert {:ok, Provider} = ProviderRegistry.get_provider(:exchange)
      assert {:ok, Provider} = ProviderRegistry.get_provider("exchange")
    end

    test "builds a client without validating, the way sync does" do
      # Deliberately missing the password. Sync builds a client from a row
      # that is already persisted and must not re-validate it, so the
      # incomplete config still yields a client; the same config through the
      # validating path is refused. The pair is what makes the skip
      # observable — a client built from a complete config proves nothing,
      # because it would build either way.
      config = %{
        base_url: "https://mail.example.com/EWS/Exchange.asmx",
        username: "user@example.com"
      }

      assert {:ok, _client} =
               ProviderRegistry.create_client(:exchange, config, skip_validation: true)

      assert {:error, _reason} = ProviderRegistry.create_client(:exchange, config)
    end
  end

  describe "the circuit breaker" do
    test "runs an exchange call rather than refusing the provider" do
      assert {:ok, :ran} = CalendarCircuitBreaker.call(:exchange, fn -> {:ok, :ran} end)
    end

    test "reports a status for exchange" do
      assert %{status: :closed} = CalendarCircuitBreaker.status(:exchange)
    end
  end
end
