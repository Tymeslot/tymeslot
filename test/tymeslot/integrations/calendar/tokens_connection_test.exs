defmodule Tymeslot.Integrations.Calendar.TokensConnectionTest do
  use Tymeslot.DataCase, async: false

  alias Tymeslot.Integrations.Calendar.{Connection, Tokens}

  describe "ensure_valid_token/2" do
    test "returns same integration when token not expired" do
      fresh =
        insert(:calendar_integration,
          provider: "google",
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        )

      assert {:ok, returned} = Tokens.ensure_valid_token(fresh, fresh.user_id)
      assert returned.id == fresh.id
      assert returned.provider == fresh.provider
      assert returned.token_expires_at == fresh.token_expires_at
    end

    test "returns unsupported for non oauth providers" do
      integration =
        insert(:calendar_integration,
          provider: "caldav",
          token_expires_at: DateTime.add(DateTime.utc_now(), -3600, :second)
        )

      assert {:error, :unsupported_provider} =
               Tokens.ensure_valid_token(integration, integration.user_id)
    end
  end

  describe "Connection.validate/3" do
    test "fails fast on unsupported provider" do
      assert {:error, :unsupported_provider} =
               Connection.validate_connection(%{provider: "unknown"}, 1)
    end

    test "delegates test_connection to the provider module" do
      previous = Application.get_env(:tymeslot, :calendar_providers)

      Application.put_env(:tymeslot, :calendar_providers, %{
        caldav: [enabled: true],
        radicale: [enabled: true],
        nextcloud: [enabled: true],
        google: [enabled: true],
        outlook: [enabled: false],
        debug: [enabled: false],
        demo: [enabled: true]
      })

      on_exit(fn -> Application.put_env(:tymeslot, :calendar_providers, previous) end)

      assert {:ok, message} = Connection.test_connection(%{provider: "demo"})
      assert message =~ "successful"
    end
  end
end
