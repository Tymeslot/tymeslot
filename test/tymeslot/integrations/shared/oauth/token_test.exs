defmodule Tymeslot.Integrations.Common.OAuth.TokenTest do
  # async: false because of shared ETS lock table
  use Tymeslot.DataCase, async: false
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Common.OAuth.Token
  alias Tymeslot.Integrations.Shared.Lock

  describe "valid?/2" do
    test "returns false if expires_at is nil" do
      refute Token.valid?(%{token_expires_at: nil})
    end

    test "returns true if token is valid with buffer" do
      expires_at = DateTime.add(DateTime.utc_now(), 600, :second)
      assert Token.valid?(%{token_expires_at: expires_at}, 300)
    end

    test "returns false if token expires within buffer" do
      expires_at = DateTime.add(DateTime.utc_now(), 200, :second)
      refute Token.valid?(%{token_expires_at: expires_at}, 300)
    end
  end

  describe "ensure_valid_access_token/2" do
    test "returns existing token if valid" do
      expires_at = DateTime.add(DateTime.utc_now(), 600, :second)
      integration = %{token_expires_at: expires_at, access_token: "current-token"}

      assert {:ok, "current-token"} =
               Token.ensure_valid_access_token(integration, refresh_fun: fn _client -> :error end)
    end

    test "refreshes and persists token if invalid" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          token_expires_at: DateTime.add(DateTime.utc_now(), -100, :second),
          access_token: "old"
        )

      new_expires_at = DateTime.add(DateTime.utc_now(), 3600, :second)
      refresh_fun = fn _client -> {:ok, {"new-access", "new-refresh", new_expires_at}} end

      assert {:ok, "new-access"} =
               Token.ensure_valid_access_token(integration, refresh_fun: refresh_fun)

      # Check persistence
      {:ok, updated} = CalendarIntegrationQueries.get(integration.id)
      assert updated.token_expires_at == DateTime.truncate(new_expires_at, :second)
    end

    test "handles refresh errors" do
      integration = %{
        token_expires_at: DateTime.add(DateTime.utc_now(), -100, :second),
        access_token: "old",
        id: 123
      }

      refresh_fun = fn _client -> {:error, :failed_refresh} end

      assert {:error, :failed_refresh} =
               Token.ensure_valid_access_token(integration, refresh_fun: refresh_fun)
    end

    test "returns error when token refresh lock cannot be acquired within timeout" do
      integration = %{
        token_expires_at: DateTime.add(DateTime.utc_now(), -100, :second),
        access_token: "old",
        id: 999_999
      }

      # Acquire the lock from another process so our call can't get it
      lock_key = {:token_refresh, 999_999}
      test_pid = self()

      holder =
        spawn(fn ->
          Lock.with_lock(
            lock_key,
            fn ->
              send(test_pid, :lock_held)
              Process.sleep(10_000)
            end,
            mode: :blocking,
            timeout: 15_000
          )
        end)

      assert_receive :lock_held, 2_000

      result =
        Token.ensure_valid_access_token(integration,
          refresh_fun: fn _client -> {:ok, {"new", "new", DateTime.utc_now()}} end,
          lock_timeout: 500
        )

      assert {:error, :lock_timeout} = result

      Process.exit(holder, :kill)
    end

    test "refreshes without lock when Lock GenServer is not running" do
      integration = %{
        token_expires_at: DateTime.add(DateTime.utc_now(), -100, :second),
        access_token: "old",
        id: :no_id
      }

      new_expires_at = DateTime.add(DateTime.utc_now(), 3600, :second)
      refresh_fun = fn _client -> {:ok, {"new_token", "new_refresh", new_expires_at}} end

      # Stop the Lock GenServer; the supervisor will restart it automatically
      GenServer.stop(Lock)

      assert {:ok, "new_token"} =
               Token.ensure_valid_access_token(integration,
                 refresh_fun: refresh_fun,
                 persist: false
               )

      # Wait for the supervisor to have restarted Lock before any other test runs
      :ok = wait_for_lock_restart()
    end

    test "skips refresh when refetch_fun returns a valid token" do
      user = insert(:user)
      valid_expires = DateTime.add(DateTime.utc_now(), 3600, :second)

      integration =
        insert(:calendar_integration,
          user: user,
          token_expires_at: DateTime.add(DateTime.utc_now(), -100, :second),
          access_token: "old"
        )

      # Simulate another process having already refreshed the token in the DB
      {:ok, _updated} =
        CalendarIntegrationQueries.update_integration(integration, %{
          access_token: "already-refreshed",
          token_expires_at: valid_expires
        })

      # refresh_fun should NOT be called because refetch_fun returns a valid token
      refresh_fun = fn _client ->
        raise "refresh_fun should not be called"
      end

      refetch_fun = fn id ->
        {:ok, fresh} = CalendarIntegrationQueries.get(id)
        CalendarIntegrationSchema.decrypt_oauth_tokens(fresh)
      end

      assert {:ok, _token} =
               Token.ensure_valid_access_token(integration,
                 refresh_fun: refresh_fun,
                 refetch_fun: refetch_fun
               )
    end
  end

  # Locks in the single-flight invariant: when two processes race to refresh
  # the same integration's expired token, only one provider HTTP call must be
  # made. Google's one-use-refresh-token policy would otherwise revoke the
  # refresh token mid-race and brick the integration.
  describe "ensure_valid_access_token/2 — concurrent refresh single-flight" do
    test "two concurrent callers trigger exactly one refresh_fun invocation" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          token_expires_at: DateTime.add(DateTime.utc_now(), -100, :second),
          access_token: "old"
        )

      new_expires_at = DateTime.add(DateTime.utc_now(), 3600, :second)
      call_count = :counters.new(1, [:atomics])
      test_pid = self()

      refresh_fun = fn _client ->
        :counters.add(call_count, 1, 1)
        # Signal the test that the lock has been acquired and we are inside
        # the refresh body. Then wait for the test to release us, ensuring
        # task_b is provably blocked on the lock before task_a completes.
        send(test_pid, :refresh_started)

        receive do
          :proceed -> :ok
        after
          1_000 -> raise "timed out waiting for :proceed in refresh_fun"
        end

        {:ok, {"refreshed-access", "refreshed-refresh", new_expires_at}}
      end

      refetch_fun = fn id ->
        case CalendarIntegrationQueries.get(id) do
          {:ok, fresh} -> CalendarIntegrationSchema.decrypt_oauth_tokens(fresh)
          {:error, _reason} = error -> error
        end
      end

      # Start task_a first and wait until it has acquired the lock and entered
      # refresh_fun — at that point the lock is held.
      task_a =
        Task.async(fn ->
          Token.ensure_valid_access_token(integration,
            refresh_fun: refresh_fun,
            refetch_fun: refetch_fun
          )
        end)

      assert_receive :refresh_started, 2_000

      # The lock is now held by task_a. Spawn task_b; it will attempt to
      # acquire the same lock and block.
      task_b =
        Task.async(fn ->
          Token.ensure_valid_access_token(integration,
            refresh_fun: refresh_fun,
            refetch_fun: refetch_fun
          )
        end)

      # Give task_b a moment to reach the lock and queue behind task_a.
      Process.sleep(50)

      # Release task_a's refresh_fun so it can write the new token and free
      # the lock. task_b then wakes, re-fetches the DB row, and short-circuits.
      send(task_a.pid, :proceed)

      assert {:ok, token_a} = Task.await(task_a, 5_000)
      assert {:ok, token_b} = Task.await(task_b, 5_000)

      # Both callers see the refreshed token — the second one through the
      # in-lock DB re-fetch rather than a duplicate refresh call.
      assert token_a == "refreshed-access"
      assert token_b == "refreshed-access"

      # Exactly one provider HTTP call — the rest short-circuit on re-fetch.
      assert :counters.get(call_count, 1) == 1
    end
  end

  # Pins the error-propagation contract introduced to stop persist_tokens/4
  # from silently swallowing DB-update failures. Prior to this change, a
  # failed write left the DB holding stale tokens while the caller received
  # `{:ok, fresh_token}` — next read re-refreshed, triggering IdP rate limits
  # or refresh-token revocation (Google's one-use policy). The fix surfaces
  # `{:error, :token_persist_failed}` so callers fail loudly instead.
  describe "ensure_valid_access_token/2 — persistence failure surfaces as :token_persist_failed" do
    test "bare-map integration whose id has no DB row" do
      # Hits the `persist_tokens(%{id: id}, ...)` fallback clause. After the
      # refresh succeeds, CalendarIntegrationQueries.get/1 returns
      # {:error, :not_found}; persist_tokens propagates it and
      # handle_refresh_result converts to the stable caller-facing error.
      integration = %{
        token_expires_at: DateTime.add(DateTime.utc_now(), -100, :second),
        access_token: "old",
        id: 999_999_999
      }

      new_expires_at = DateTime.add(DateTime.utc_now(), 3600, :second)
      refresh_fun = fn _client -> {:ok, {"fresh-access", "fresh-refresh", new_expires_at}} end

      assert {:error, :token_persist_failed} =
               Token.ensure_valid_access_token(integration, refresh_fun: refresh_fun)
    end

    test "schema struct whose changeset validation fails at Repo.update" do
      # Hits the `persist_tokens(%CalendarIntegrationSchema{}, ...)` primary
      # clause. The struct's :name is forced to nil so that the changeset's
      # validate_required([:name, :provider, :user_id]) fires at update time
      # — Repo.update returns {:error, changeset}, which persist_tokens now
      # propagates instead of masking.
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          token_expires_at: DateTime.add(DateTime.utc_now(), -100, :second),
          access_token: "old"
        )

      tainted = %{integration | name: nil}

      new_expires_at = DateTime.add(DateTime.utc_now(), 3600, :second)
      refresh_fun = fn _client -> {:ok, {"fresh-access", "fresh-refresh", new_expires_at}} end

      assert {:error, :token_persist_failed} =
               Token.ensure_valid_access_token(tainted, refresh_fun: refresh_fun)
    end
  end

  # Polls until the Lock GenServer has been restarted by its supervisor, with a
  # short backoff so we don't busy-wait. Used after deliberately stopping Lock.
  defp wait_for_lock_restart(retries \\ 50) do
    case GenServer.whereis(Tymeslot.Integrations.Shared.Lock) do
      nil when retries > 0 ->
        Process.sleep(10)
        wait_for_lock_restart(retries - 1)

      nil ->
        raise "Lock GenServer did not restart within the expected time"

      _pid ->
        :ok
    end
  end
end
