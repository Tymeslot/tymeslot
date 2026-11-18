defmodule Tymeslot.Integrations.Calendar.CalendarIntegrationQueriesTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :queries
  @moduletag :security

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries

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

      assert byte_size(raw_integration.username_encrypted) > 0
      assert byte_size(raw_integration.password_encrypted) > 0
      refute String.contains?(raw_integration.username_encrypted, "secretuser")
      refute String.contains?(raw_integration.password_encrypted, "secretpass")

      # But decrypted when retrieved through queries
      {:ok, retrieved} = CalendarIntegrationQueries.get(integration.id)
      assert retrieved.username == "secretuser"
      assert retrieved.password == "secretpass"
    end
  end

  describe "get_for_user/2 with a stale encryption key" do
    test "returns {:error, :requires_reencryption, integration} when credentials cannot be decrypted" do
      user = insert(:user)

      # Undecryptable bytes stand in for a credential whose key is genuinely gone.
      integration =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          username_encrypted: :crypto.strong_rand_bytes(40),
          password_encrypted: :crypto.strong_rand_bytes(40)
        )

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

      assert "Enter a full address starting with https://, for example https://example.com" in errors_on(
               changeset
             ).base_url
    end
  end
end
