defmodule Tymeslot.Infrastructure.CircuitBreakerSupervisorTest do
  use ExUnit.Case, async: false

  @moduletag :infrastructure

  alias Tymeslot.Infrastructure.CircuitBreaker
  alias Tymeslot.Infrastructure.CircuitBreakerRegistry
  alias Tymeslot.Infrastructure.CircuitBreakerSupervisor
  alias Tymeslot.Infrastructure.DynamicCircuitBreakerSupervisor
  alias Tymeslot.Infrastructure.ProviderBreakers
  alias Tymeslot.Integrations.Calendar.ProviderConfig, as: CalendarProviderConfig
  alias Tymeslot.Integrations.Video.ProviderConfig, as: VideoProviderConfig

  @static_breakers [:email_service_breaker]

  describe "supervisor started" do
    test "supervises a breaker for every provider that has circuit breaking enabled" do
      assert is_pid(Process.whereis(CircuitBreakerSupervisor))

      supervised =
        CircuitBreakerSupervisor
        |> Supervisor.which_children()
        |> MapSet.new(fn {id, _pid, _type, _modules} -> id end)

      expected =
        Enum.map(enabled_calendar_providers(), &breaker_atom("calendar_breaker_#{&1}")) ++
          Enum.map(enabled_video_providers(), &breaker_atom("video_breaker_#{&1}")) ++
          @static_breakers

      # A provider list is never empty, so an accidentally empty expectation
      # would otherwise make this test pass vacuously.
      assert length(expected) > length(@static_breakers)

      for id <- expected do
        assert MapSet.member?(supervised, id), "Expected #{id} to be supervised"
      end
    end
  end

  describe "calendar breakers" do
    test "all calendar provider breakers are alive" do
      for provider <- enabled_calendar_providers() do
        name = breaker_atom("calendar_breaker_#{provider}")

        assert is_pid(Process.whereis(name)), "Expected #{name} to be running"
        assert %{status: :closed} = CircuitBreaker.status(name)
      end
    end
  end

  describe "video breakers" do
    test "all video provider breakers are alive" do
      for provider <- enabled_video_providers() do
        name = breaker_atom("video_breaker_#{provider}")

        assert is_pid(Process.whereis(name)), "Expected #{name} to be running"
        assert %{status: :closed} = CircuitBreaker.status(name)
      end
    end
  end

  describe "a video provider switched off" do
    setup do
      prior = Application.fetch_env(:tymeslot, :video_providers)

      on_exit(fn ->
        case prior do
          {:ok, value} -> Application.put_env(:tymeslot, :video_providers, value)
          :error -> Application.delete_env(:tymeslot, :video_providers)
        end
      end)
    end

    # Its existing integrations keep making room calls, and without a breaker
    # every one of them would fail with `:breaker_not_found`.
    test "keeps its breaker when the application starts" do
      Application.put_env(:tymeslot, :video_providers, %{zoom: %{enabled: false}})
      refute :zoom in VideoProviderConfig.all_providers()

      {:ok, {_flags, children}} = CircuitBreakerSupervisor.init([])

      assert :video_breaker_zoom in Enum.map(children, & &1.id)
    end
  end

  describe "other breakers" do
    test "email service breaker is alive" do
      assert is_pid(Process.whereis(:email_service_breaker))
      assert %{status: :closed} = CircuitBreaker.status(:email_service_breaker)
    end
  end

  describe "Registry and DynamicSupervisor" do
    test "a host-keyed breaker starts under the dynamic supervisor and is found in the registry" do
      name = {:via, Registry, {CircuitBreakerRegistry, "circuit-breaker-supervisor-test.example"}}

      refute ProviderBreakers.breaker_exists?(name)

      assert {:ok, pid} =
               DynamicSupervisor.start_child(
                 DynamicCircuitBreakerSupervisor,
                 {CircuitBreaker, name: name, config: %{}}
               )

      on_exit(fn ->
        if Process.alive?(pid) do
          DynamicSupervisor.terminate_child(DynamicCircuitBreakerSupervisor, pid)
        end
      end)

      assert ProviderBreakers.breaker_exists?(name)
      assert %{status: :closed} = CircuitBreaker.status(name)
    end
  end

  defp enabled_calendar_providers do
    Enum.filter(
      CalendarProviderConfig.all_providers(),
      &CalendarProviderConfig.circuit_breaker_enabled?/1
    )
  end

  defp enabled_video_providers do
    Enum.filter(
      VideoProviderConfig.all_providers(),
      &VideoProviderConfig.circuit_breaker_enabled?/1
    )
  end

  # The supervisor creates these atoms at boot, so they must already exist;
  # a missing one means the breaker was never started.
  defp breaker_atom(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError ->
      flunk("Atom #{name} not found — is CircuitBreakerSupervisor running?")
  end
end
