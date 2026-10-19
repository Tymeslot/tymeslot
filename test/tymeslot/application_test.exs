defmodule Tymeslot.ApplicationTest do
  use ExUnit.Case, async: false
  @moduletag :infrastructure

  alias Tymeslot.CalendarGrid.WriteGuardianSupervisor

  alias Tymeslot.Infrastructure.{
    AvailabilityCache,
    CircuitBreaker,
    CircuitBreakerSupervisor,
    DashboardCache
  }

  alias Tymeslot.Integrations.Calendar.Runtime.RequestCoalescer
  alias Tymeslot.Payments.Webhooks.IdempotencyCache
  alias Tymeslot.Security.RateLimit

  describe "core application services" do
    # These four children are third-party processes (Phoenix.PubSub, Ecto, Finch,
    # Task.Supervisor) registered under Tymeslot-owned names. There is no
    # application function to call: the registration itself is what this guards,
    # and dropping a child spec is exactly the regression it catches.
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "base children are registered under their application names" do
      for name <- [Tymeslot.PubSub, Tymeslot.Repo, Tymeslot.Finch, Tymeslot.TaskSupervisor] do
        assert is_pid(Process.whereis(name)), "#{inspect(name)} is not running"
      end
    end

    test "infrastructure caches are started and serve reads" do
      key = {:application_test, System.unique_integer([:positive])}

      assert :ok = DashboardCache.put(key, :cached)
      assert DashboardCache.get_or_compute(key, fn -> :recomputed end) == :cached
      DashboardCache.invalidate(key)

      assert :ok = AvailabilityCache.put(key, :cached)
      assert AvailabilityCache.get_or_compute(key, fn -> :recomputed end) == :cached
      AvailabilityCache.invalidate(key)

      # IdempotencyCache reads through to the database, which this module has no
      # sandbox connection for; its process being up is what the tree guarantees.
      assert is_pid(Process.whereis(IdempotencyCache))
    end

    test "security services are started" do
      # A first hit against a fresh bucket proves the limiter's table is up.
      bucket = "application-test:#{System.unique_integer([:positive])}"
      assert RateLimit.hit(bucket, 60_000, 5) == {:allow, 1}
    end

    test "Oban is started" do
      # Oban registers itself in Oban.Registry rather than under a local name,
      # so Oban.whereis/1 is the supported lookup.
      assert is_pid(Oban.whereis(Oban))
    end

    test "CircuitBreakerSupervisor is started with its named breakers" do
      assert %{status: :closed} = CircuitBreaker.status(:email_service_breaker)
    end

    test "RequestCoalescer is started and runs fetches" do
      today = Date.utc_today()

      assert RequestCoalescer.coalesce(1, today, today, fn -> {:ok, [%{uid: "evt-1"}]} end) ==
               {:ok, [%{uid: "evt-1"}]}
    end
  end

  describe "shutdown order" do
    # Children stop in reverse start order. A calendar grid's write guardian
    # drives its queue once the Endpoint has taken its LiveView down, and
    # saves what is left when it is stopped itself, so everything it writes
    # through must still be up when it stops. The tree's order is the
    # behaviour, and there is no application function to call for it.
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "the write guardians stop right after the Endpoint, before what they write through" do
      start_order =
        Tymeslot.Supervisor
        |> Supervisor.which_children()
        |> Enum.map(fn {id, _pid, _type, _modules} -> id end)
        |> Enum.reverse()

      position = fn id ->
        Enum.find_index(start_order, &(&1 == id)) || flunk("#{inspect(id)} is not a child")
      end

      guardians = position.(WriteGuardianSupervisor)

      assert position.(TymeslotWeb.Endpoint) == guardians + 1

      for dependency <- [
            CircuitBreakerSupervisor,
            Oban,
            AvailabilityCache,
            Tymeslot.TaskSupervisor,
            Tymeslot.Repo
          ] do
        assert position.(dependency) < guardians,
               "#{inspect(dependency)} would stop before the write guardians"
      end
    end
  end

  describe "start order" do
    # Oban's queues start fetching during its own init, so every process a
    # job calls has to be up before it, and still up while it drains on
    # shutdown. The tree's order is the behaviour.
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "Oban starts after the services its jobs call" do
      start_order =
        Tymeslot.Supervisor
        |> Supervisor.which_children()
        |> Enum.map(fn {id, _pid, _type, _modules} -> id end)
        |> Enum.reverse()

      position = fn id ->
        Enum.find_index(start_order, &(&1 == id)) || flunk("#{inspect(id)} is not a child")
      end

      oban = position.(Oban)

      for dependency <- [
            CircuitBreakerSupervisor,
            RateLimit,
            AvailabilityCache,
            DashboardCache,
            IdempotencyCache,
            RequestCoalescer,
            Tymeslot.Repo
          ] do
        assert position.(dependency) < oban,
               "#{inspect(dependency)} starts after Oban"
      end
    end
  end

  describe "admin settings" do
    # The overrides an admin set (registration disabled, reCAPTCHA required)
    # must be in force before anything serves a request or runs a job. The
    # loader leaves no process behind, but the supervisor keeps its spec.
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "are applied after the Repo and before Oban and the Endpoint" do
      start_order =
        Tymeslot.Supervisor
        |> Supervisor.which_children()
        |> Enum.map(fn {id, _pid, _type, _modules} -> id end)
        |> Enum.reverse()

      position = fn id ->
        Enum.find_index(start_order, &(&1 == id)) || flunk("#{inspect(id)} is not a child")
      end

      loader = position.(Tymeslot.AppSettings.Loader)

      assert position.(Tymeslot.Repo) < loader
      assert loader < position.(Oban)
      assert loader < position.(TymeslotWeb.Endpoint)
    end
  end

  # Oban queue merging, validation, and the "no queues configured" fallback are
  # covered against the real implementation in
  # Tymeslot.Infrastructure.ObanQueuesTest.
end
