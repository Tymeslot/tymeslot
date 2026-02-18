defmodule Tymeslot.Integrations.Common.OAuth.TokenTest do
  # async: false because of :global.trans
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
  end
end
