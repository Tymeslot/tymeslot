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
  alias Tymeslot.Integrations.Calendar.Providers.ProviderRegistry

  setup do
    CalendarCircuitBreaker.reset(:exchange)
    :ok
  end

  describe "the registry" do
    test "resolves exchange from both the atom and the stored string" do
      assert {:ok, Provider} = ProviderRegistry.get_provider(:exchange)
      assert {:ok, Provider} = ProviderRegistry.get_provider("exchange")
    end

    test "builds a client without validating, the way sync does" do
      config = %{
        base_url: "https://mail.example.com/EWS/Exchange.asmx",
        username: "user@example.com",
        password: "secret"
      }

      assert {:ok, client} =
               ProviderRegistry.create_client(:exchange, config, skip_validation: true)

      assert client.base_url == "https://mail.example.com/EWS/Exchange.asmx"
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
