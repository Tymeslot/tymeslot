defmodule Tymeslot.Integrations.Common.OAuth.TokenTest do
  # async: false because of shared ETS lock table
  use Tymeslot.DataCase, async: false
  @moduletag :integrations

  alias Tymeslot.DatabaseQueries.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Common.OAuth.Token

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
          Tymeslot.Integrations.Shared.Lock.with_lock(
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
      {:ok, _} =
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
        Tymeslot.DatabaseSchemas.CalendarIntegrationSchema.decrypt_oauth_tokens(fresh)
      end

      assert {:ok, _token} =
               Token.ensure_valid_access_token(integration,
                 refresh_fun: refresh_fun,
                 refetch_fun: refetch_fun
               )
    end
  end
end
