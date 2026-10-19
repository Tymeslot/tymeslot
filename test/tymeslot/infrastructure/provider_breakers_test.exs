defmodule Tymeslot.Infrastructure.ProviderBreakersTest do
  # Provider-level breakers are global named processes, and `reset_all_hosts/0`
  # touches every host breaker, so this module runs alone.
  use ExUnit.Case, async: false

  @moduletag :infrastructure

  import ExUnit.CaptureLog

  alias Tymeslot.Infrastructure.{
    CalendarCircuitBreaker,
    CircuitBreaker,
    ProviderBreakers,
    VideoCircuitBreaker
  }

  @registry Tymeslot.Infrastructure.CircuitBreakerRegistry

  # A self-hosted and an OAuth provider of each kind.
  @kinds [
    calendar: %{host_provider: :caldav, oauth_provider: :google},
    video: %{host_provider: :mirotalk, oauth_provider: :teams}
  ]

  setup do
    reset = fn ->
      for {kind, %{oauth_provider: provider}} <- @kinds,
          do: ProviderBreakers.reset(kind, provider)

      ProviderBreakers.reset_all_hosts()
    end

    reset.()
    on_exit(reset)
  end

  defp unique_host, do: "breakers-#{System.unique_integer([:positive])}.example.com"

  defp trip(kind, provider, host) do
    for _attempt <- 1..ProviderBreakers.config(kind, provider).failure_threshold do
      ProviderBreakers.call_with_host(kind, provider, host, fn -> {:provider_error, :down} end)
    end

    # Outcomes are recorded by cast; a call to the same breaker is queued
    # behind them, so its reply means every failure has been counted.
    ProviderBreakers.status(kind, provider, host)
  end

  for {kind, %{host_provider: host_provider, oauth_provider: oauth_provider}} <- @kinds do
    @kind kind
    @host_provider host_provider
    @oauth_provider oauth_provider

    describe "#{kind} breakers" do
      test "run a call through the provider breaker and return its result" do
        assert {:ok, 42} = ProviderBreakers.call(@kind, @oauth_provider, fn -> {:ok, 42} end)
        assert :ok = ProviderBreakers.call(@kind, @oauth_provider, fn -> :ok end)
      end

      test "translate a provider error and log it" do
        log =
          capture_log(fn ->
            assert {:error, :api_timeout} =
                     ProviderBreakers.call(@kind, @oauth_provider, fn ->
                       {:provider_error, :api_timeout}
                     end)
          end)

        assert log =~ "Operation failed"
      end

      test "refuse a provider that has no breaker" do
        assert {:error, {:invalid_provider, :nope}} =
                 ProviderBreakers.call(@kind, :nope, fn -> {:ok, :ran} end)

        assert {:error, {:invalid_provider, :nope}} = ProviderBreakers.status(@kind, :nope)
        assert {:error, {:invalid_provider, :nope}} = ProviderBreakers.reset(@kind, :nope)
      end

      test "open a host breaker without touching the provider breaker or another host" do
        host = unique_host()
        other_host = unique_host()

        assert %{status: :open} = trip(@kind, @host_provider, host)

        log =
          capture_log(fn ->
            assert {:error, :circuit_open} =
                     ProviderBreakers.with_breaker(@kind, @host_provider, [host: host], fn ->
                       {:ok, :ran}
                     end)
          end)

        assert log =~ "Host circuit breaker open"

        assert {:ok, :ran} =
                 ProviderBreakers.with_breaker(@kind, @host_provider, [host: other_host], fn ->
                   {:ok, :ran}
                 end)

        refute match?(%{status: :open}, ProviderBreakers.status(@kind, @host_provider))
      end

      test "status and reset read the breaker a call to the base URL trips" do
        host = unique_host()
        base_url = "https://#{String.upcase(host)}/dav/"

        trip(@kind, @host_provider, host)

        breaker_host = ProviderBreakers.host_from_base_url(base_url)
        assert %{status: :open} = ProviderBreakers.status(@kind, @host_provider, breaker_host)

        assert :ok = ProviderBreakers.reset(@kind, @host_provider, breaker_host)
        assert %{status: :closed} = ProviderBreakers.status(@kind, @host_provider, host)
      end

      test "report a host breaker that was never started as not found" do
        assert {:error, :breaker_not_found} =
                 ProviderBreakers.status(@kind, @host_provider, unique_host())
      end
    end
  end

  describe "host breaker names" do
    test "hosts differing only in punctuation get distinct breakers" do
      suffix = System.unique_integer([:positive])
      dashed = "cal.a-b-#{suffix}.example"
      dotted = "cal.a.b-#{suffix}.example"

      assert %{status: :open} = trip(:calendar, :caldav, dashed)

      assert {:ok, :ran} =
               ProviderBreakers.call_with_host(:calendar, :caldav, dotted, fn -> {:ok, :ran} end)
    end

    test "a host's case does not split its breaker" do
      host = unique_host()
      trip(:calendar, :caldav, String.upcase(host))

      assert {:error, :circuit_open} =
               ProviderBreakers.call_with_host(:calendar, :caldav, host, fn -> {:ok, :ran} end)
    end

    test "the same host of another kind or provider is a separate breaker" do
      host = unique_host()
      trip(:calendar, :caldav, host)

      assert {:ok, :ran} =
               ProviderBreakers.call_with_host(:calendar, :nextcloud, host, fn -> {:ok, :ran} end)

      assert {:ok, :ran} =
               ProviderBreakers.call_with_host(:video, :mirotalk, host, fn -> {:ok, :ran} end)
    end
  end

  describe "host_from_base_url/1" do
    test "takes the host of a URL and nothing from anything else" do
      assert ProviderBreakers.host_from_base_url("https://dav.example.com:8443/x") ==
               "dav.example.com"

      assert ProviderBreakers.host_from_base_url("not a url") == nil
      assert ProviderBreakers.host_from_base_url(nil) == nil
    end
  end

  describe "a breaker that dies mid-call" do
    test "returns an error instead of exiting the caller" do
      host = unique_host()
      {:via, Registry, {@registry, key}} = ProviderBreakers.name(:calendar, :caldav, host)
      test_pid = self()

      # A process registered under the breaker's name that exits on the call,
      # as a breaker idling out between the lookup and the call would.
      spawn(fn ->
        Registry.register(@registry, key, nil)
        send(test_pid, :registered)

        receive do
          {:"$gen_call", _from, _request} -> exit(:simulated_crash)
        end
      end)

      assert_receive :registered

      capture_log(fn ->
        assert {:error, :circuit_breaker_error} =
                 ProviderBreakers.call_with_host(:calendar, :caldav, host, fn -> {:ok, :ran} end)
      end)
    end
  end

  describe "reset_all_hosts/0" do
    test "clears the persisted snapshot of a tripped host breaker, not just its live state" do
      host = unique_host()
      name = ProviderBreakers.name(:calendar, :google, host)
      trip(:calendar, :google, host)

      assert [{^name, %{status: :open}}] = :ets.lookup(:circuit_breaker_state_table, name)

      ProviderBreakers.reset_all_hosts()
      # reset/1 re-persists `:closed` by cast; wait on the same process.
      CircuitBreaker.status(name)

      assert [{^name, %{status: :closed}}] = :ets.lookup(:circuit_breaker_state_table, name)
    end
  end

  describe "configuration" do
    test "lenient settings for OAuth providers and Nextcloud, defaults for the rest" do
      lenient = %{failure_threshold: 5, recovery_timeout: :timer.minutes(5)}
      default = %{failure_threshold: 3, recovery_timeout: :timer.minutes(2)}

      for {kind, provider, expected} <- [
            {:calendar, :google, lenient},
            {:calendar, :outlook, lenient},
            {:calendar, :caldav, default},
            {:calendar, :exchange, default},
            {:calendar, :nextcloud, %{failure_threshold: 4, recovery_timeout: :timer.minutes(3)}},
            {:video, :google_meet, lenient},
            {:video, :teams, lenient},
            {:video, :mirotalk, default}
          ] do
        assert Map.take(ProviderBreakers.config(kind, provider), Map.keys(expected)) == expected,
               "#{kind} #{provider}"
      end
    end

    test "the supervisor starts each provider breaker with its configuration" do
      for kind <- [:calendar, :video], provider <- ProviderBreakers.providers(kind) do
        expected = ProviderBreakers.config(kind, provider)

        assert %{config: ^expected} =
                 :sys.get_state(ProviderBreakers.name(kind, provider)),
               "#{kind} #{provider}"
      end
    end

    test "the wrappers delegate to their kind" do
      assert CalendarCircuitBreaker.get_config(:google) ==
               ProviderBreakers.config(:calendar, :google)

      assert VideoCircuitBreaker.get_config(:teams) == ProviderBreakers.config(:video, :teams)
    end

    test "video jobs snooze past the longest video recovery timeout" do
      longest_ms =
        :video
        |> ProviderBreakers.providers()
        |> Enum.map(&ProviderBreakers.config(:video, &1).recovery_timeout)
        |> Enum.max()

      assert VideoCircuitBreaker.max_recovery_seconds() == div(longest_ms, 1_000)
      assert VideoCircuitBreaker.max_recovery_seconds() == 300
    end
  end
end
