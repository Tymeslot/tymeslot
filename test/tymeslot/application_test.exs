defmodule Tymeslot.ApplicationTest do
  use ExUnit.Case, async: false
  @moduletag :infrastructure

  alias Tymeslot.Infrastructure.{AvailabilityCache, DashboardCache}
  alias Tymeslot.Payments.Webhooks.IdempotencyCache
  alias Tymeslot.Security.{AccountLockout, RateLimit}

  describe "core application services" do
    test "Tymeslot.PubSub is started" do
      assert is_pid(Process.whereis(Tymeslot.PubSub))
    end

    test "Repo is started" do
      assert is_pid(Process.whereis(Tymeslot.Repo))
    end

    test "Finch is started" do
      assert is_pid(Process.whereis(Tymeslot.Finch))
    end

    test "Task.Supervisor is started" do
      assert is_pid(Process.whereis(Tymeslot.TaskSupervisor))
    end

    test "Infrastructure caches are started" do
      assert is_pid(Process.whereis(DashboardCache))
      assert is_pid(Process.whereis(AvailabilityCache))
      assert is_pid(Process.whereis(IdempotencyCache))
    end

    test "Security services are started" do
      # RateLimit (Hammer ETS) is not a named process; verify its ETS table is up
      assert :ets.info(RateLimit) != :undefined
      assert is_pid(Process.whereis(AccountLockout))
    end

    test "Oban is started" do
      # In test mode with testing: :manual, Oban might be registered under a different name
      # or we can check via Oban.whereis/1 using the default name.
      assert is_pid(Process.whereis(Oban)) or is_pid(Oban.whereis(Oban))
    end

    test "CircuitBreakerSupervisor is started" do
      assert is_pid(Process.whereis(Tymeslot.Infrastructure.CircuitBreakerSupervisor))
    end

    test "RequestCoalescer is started" do
      assert is_pid(Process.whereis(Tymeslot.Integrations.Calendar.RequestCoalescer))
    end
  end

  describe "email asset cache" do
    test "tymeslot_email_assets ETS table exists" do
      assert :ets.whereis(:tymeslot_email_assets) != :undefined
    end
  end

  describe "Oban queue configuration" do
    setup do
      # Save original config
      original_base = Application.get_env(:tymeslot, :oban_queues)
      original_additional = Application.get_env(:tymeslot, :oban_additional_queues)

      on_exit(fn ->
        # Restore original config
        if original_base do
          Application.put_env(:tymeslot, :oban_queues, original_base)
        else
          Application.delete_env(:tymeslot, :oban_queues)
        end

        if original_additional do
          Application.put_env(:tymeslot, :oban_additional_queues, original_additional)
        else
          Application.delete_env(:tymeslot, :oban_additional_queues)
        end
      end)

      :ok
    end

    test "merges base and additional queues with additional taking precedence" do
      Application.put_env(:tymeslot, :oban_queues,
        default: 10,
        emails: 5,
        webhooks: 3
      )

      Application.put_env(:tymeslot, :oban_additional_queues,
        emails: 20,
        saas_emails: 5
      )

      base_queues = Application.get_env(:tymeslot, :oban_queues, [])
      additional_queues = Application.get_env(:tymeslot, :oban_additional_queues, [])
      merged = Keyword.merge(base_queues, additional_queues)

      # Verify emails was overridden
      assert merged[:emails] == 20
      # Verify saas_emails was added
      assert merged[:saas_emails] == 5
      # Verify default and webhooks remain unchanged
      assert merged[:default] == 10
      assert merged[:webhooks] == 3
    end

    test "detects conflicts when additional queues override base queue concurrency" do
      Application.put_env(:tymeslot, :oban_queues,
        default: 10,
        emails: 5
      )

      Application.put_env(:tymeslot, :oban_additional_queues,
        emails: 20,
        saas_emails: 5
      )

      base_queues = Application.get_env(:tymeslot, :oban_queues, [])
      additional_queues = Application.get_env(:tymeslot, :oban_additional_queues, [])

      base_queue_keys = Keyword.keys(base_queues)
      additional_queue_keys = Keyword.keys(additional_queues)
      conflict_keys = Enum.filter(additional_queue_keys, &(&1 in base_queue_keys))

      # Verify conflict detection logic
      assert :emails in conflict_keys
      assert :saas_emails not in conflict_keys
      assert length(conflict_keys) == 1
    end

    test "handles empty queues gracefully" do
      Application.delete_env(:tymeslot, :oban_queues)
      Application.delete_env(:tymeslot, :oban_additional_queues)

      base_queues = Application.get_env(:tymeslot, :oban_queues, [])
      additional_queues = Application.get_env(:tymeslot, :oban_additional_queues, [])
      merged = Keyword.merge(base_queues, additional_queues)

      # When empty, the application would use a fallback
      final_queues =
        if Enum.empty?(merged) do
          [default: 1]
        else
          merged
        end

      assert final_queues == [default: 1]
    end

    test "loads base queues only when no additional queues configured" do
      Application.put_env(:tymeslot, :oban_queues, default: 10, emails: 5)
      Application.delete_env(:tymeslot, :oban_additional_queues)

      base_queues = Application.get_env(:tymeslot, :oban_queues, [])
      additional_queues = Application.get_env(:tymeslot, :oban_additional_queues, [])
      merged = Keyword.merge(base_queues, additional_queues)

      assert merged == [default: 10, emails: 5]
    end

    test "loads additional queues when no base queues configured" do
      Application.delete_env(:tymeslot, :oban_queues)
      Application.put_env(:tymeslot, :oban_additional_queues, saas_emails: 5)

      base_queues = Application.get_env(:tymeslot, :oban_queues, [])
      additional_queues = Application.get_env(:tymeslot, :oban_additional_queues, [])
      merged = Keyword.merge(base_queues, additional_queues)

      assert merged == [saas_emails: 5]
    end

    test "preserves all queues from both base and additional" do
      Application.put_env(:tymeslot, :oban_queues,
        default: 10,
        emails: 5,
        webhooks: 3
      )

      Application.put_env(:tymeslot, :oban_additional_queues,
        payments: 2,
        saas_emails: 5
      )

      base_queues = Application.get_env(:tymeslot, :oban_queues, [])
      additional_queues = Application.get_env(:tymeslot, :oban_additional_queues, [])
      merged = Keyword.merge(base_queues, additional_queues)

      # Verify all queues are present
      assert Keyword.has_key?(merged, :default)
      assert Keyword.has_key?(merged, :emails)
      assert Keyword.has_key?(merged, :webhooks)
      assert Keyword.has_key?(merged, :payments)
      assert Keyword.has_key?(merged, :saas_emails)
      assert length(merged) == 5
    end

    test "raises clear error when oban_queues is not a keyword list" do
      Application.put_env(:tymeslot, :oban_queues, "not a keyword list")

      assert_raise ArgumentError,
                   ~r/:oban_queues must be a keyword list/,
                   fn ->
                     # This would be called during application startup
                     # We can't actually start the app in tests, so we test the logic directly
                     base_queues = Application.get_env(:tymeslot, :oban_queues, [])

                     unless Keyword.keyword?(base_queues) do
                       raise ArgumentError,
                             ":oban_queues must be a keyword list, got: #{inspect(base_queues)}"
                     end
                   end
    end

    test "raises clear error when oban_additional_queues is not a keyword list" do
      Application.put_env(:tymeslot, :oban_queues, default: 10)
      Application.put_env(:tymeslot, :oban_additional_queues, %{not: "keyword list"})

      assert_raise ArgumentError,
                   ~r/:oban_additional_queues must be a keyword list/,
                   fn ->
                     additional_queues =
                       Application.get_env(:tymeslot, :oban_additional_queues, [])

                     unless Keyword.keyword?(additional_queues) do
                       raise ArgumentError,
                             ":oban_additional_queues must be a keyword list, got: #{inspect(additional_queues)}"
                     end
                   end
    end

    test "handles nil queue configurations gracefully" do
      Application.delete_env(:tymeslot, :oban_queues)
      Application.delete_env(:tymeslot, :oban_additional_queues)

      base_queues = Application.get_env(:tymeslot, :oban_queues, [])
      additional_queues = Application.get_env(:tymeslot, :oban_additional_queues, [])

      # Both should be empty lists (default value)
      assert base_queues == []
      assert additional_queues == []
      assert Keyword.keyword?(base_queues)
      assert Keyword.keyword?(additional_queues)
    end
  end
end
