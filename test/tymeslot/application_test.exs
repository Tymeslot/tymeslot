defmodule Tymeslot.ApplicationTest do
  use ExUnit.Case, async: false
  @moduletag :infrastructure

  alias Tymeslot.Infrastructure.{AvailabilityCache, CircuitBreaker, DashboardCache}
  alias Tymeslot.Integrations.Calendar.RequestCoalescer
  alias Tymeslot.Payments.Webhooks.IdempotencyCache
  alias Tymeslot.Security.AccountLockout
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
      identifier = "application-test-#{System.unique_integer([:positive])}@example.com"
      on_exit(fn -> AccountLockout.clear_failed_attempts(identifier) end)

      # AccountLockout is a plain module backed by ETS; the table is owned by
      # AccountLockout.TableOwner in the supervision tree, so a recorded attempt
      # round-tripping proves the owner started.
      assert AccountLockout.get_failed_attempt_count(identifier) == 0
      assert AccountLockout.check_and_record_attempt(identifier, false) == :ok
      assert AccountLockout.get_failed_attempt_count(identifier) == 1

      # RateLimit (Hammer ETS) is not a named process; a first hit against a
      # fresh bucket proves its table is up.
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

  # Oban queue merging, validation, and the "no queues configured" fallback are
  # covered against the real implementation in
  # Tymeslot.Infrastructure.ObanQueuesTest.
end
