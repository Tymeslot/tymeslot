defmodule Tymeslot.Integrations.Calendar.CalendarIntegrationQueriesTest do
  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :queries
  @moduletag :security

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Security.Encryption

  @endpoint TymeslotWeb.Endpoint
  @key_a String.duplicate("a", 64)
  @key_b String.duplicate("b", 64)

  setup do
    original = Application.get_env(:tymeslot, @endpoint)

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:tymeslot, @endpoint)
      else
        Application.put_env(:tymeslot, @endpoint, original)
      end
    end)

    :ok
  end

  defp put_secret_key(key) do
    base = Application.get_env(:tymeslot, @endpoint) || []

    base
    |> Keyword.put(:secret_key_base, key)
    |> then(&Application.put_env(:tymeslot, @endpoint, &1))
  end

  describe "security isolation" do
    test "prevents access to other users' integrations" do
      user1 = insert(:user)
      user2 = insert(:user)
      integration = insert(:calendar_integration, user: user1)

      result = CalendarIntegrationQueries.get_for_user(integration.id, user2.id)
      assert result == {:error, :not_found}
    end

    test "encrypts credentials in database" do
      user = insert(:user)

      attrs = %{
        name: "Secure Calendar",
        provider: "caldav",
        base_url: "https://calendar.example.com",
        username: "secretuser",
        password: "secretpass",
        user_id: user.id
      }

      {:ok, integration} = CalendarIntegrationQueries.create(attrs)

      # Verify credentials are encrypted in database
      raw_integration =
        Repo.get(Tymeslot.Integrations.Calendar.CalendarIntegrationSchema, integration.id)

      assert raw_integration.username_encrypted != nil
      assert raw_integration.password_encrypted != nil
      refute raw_integration.username_encrypted == "secretuser"
      refute raw_integration.password_encrypted == "secretpass"

      # But decrypted when retrieved through queries
      {:ok, retrieved} = CalendarIntegrationQueries.get(integration.id)
      assert retrieved.username == "secretuser"
      assert retrieved.password == "secretpass"
    end
  end

  describe "get_for_user/2 with a stale encryption key" do
    test "returns {:error, :requires_reencryption, integration} when credentials were encrypted under a different key" do
      put_secret_key(@key_a)
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          username_encrypted: Encryption.encrypt("myuser"),
          password_encrypted: Encryption.encrypt("mypassword")
        )

      # Simulate key rotation without re-encrypting existing rows.
      put_secret_key(@key_b)

      assert {:error, :requires_reencryption, stale} =
               CalendarIntegrationQueries.get_for_user(integration.id, user.id)

      assert stale.id == integration.id
    end
  end

  describe "business logic" do
    test "only returns active integrations for calendar sync" do
      user = insert(:user)
      active_integration = insert(:calendar_integration, user: user, is_active: true)
      insert(:calendar_integration, user: user, is_active: false)

      result = CalendarIntegrationQueries.list_active_for_user(user.id)

      assert length(result) == 1
      assert hd(result).id == active_integration.id
    end

    test "enforces valid URL format for calendar endpoints" do
      user = insert(:user)

      attrs = %{
        name: "Invalid Calendar",
        provider: "caldav",
        base_url: "javascript:alert(1)",
        user_id: user.id
      }

      {:error, changeset} = CalendarIntegrationQueries.create(attrs)
      assert "Only HTTP and HTTPS URLs are allowed" in errors_on(changeset).base_url
    end
  end
end
