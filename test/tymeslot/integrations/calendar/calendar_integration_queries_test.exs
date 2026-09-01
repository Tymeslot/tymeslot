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
      assert "Only HTTP and HTTPS URLs are allowed" in errors_on(changeset).base_url
    end
  end

  describe "deselect_calendars/2" do
    test "marks matching calendars as unselected and leaves others untouched" do
      integration =
        insert(:calendar_integration,
          provider: "google",
          calendar_list: [
            %{"id" => "primary", "selected" => true, "name" => "Primary"},
            %{"id" => "gone@example.com", "selected" => true, "name" => "Gone"}
          ]
        )

      {:ok, updated} =
        CalendarIntegrationQueries.deselect_calendars(integration, ["gone@example.com"])

      assert Enum.find(updated.calendar_list, &(&1.id == "gone@example.com")).selected ==
               false

      assert Enum.find(updated.calendar_list, &(&1.id == "primary")).selected == true
    end

    test "is a no-op that persists unchanged when no ids match" do
      integration =
        insert(:calendar_integration,
          provider: "google",
          calendar_list: [%{"id" => "primary", "selected" => true, "name" => "Primary"}]
        )

      {:ok, updated} =
        CalendarIntegrationQueries.deselect_calendars(integration, ["nonexistent@example.com"])

      assert updated.calendar_list == integration.calendar_list
    end
  end

  describe "toggle_active/1 — reactivation conflicts" do
    test "returns {:error, :duplicate_account} instead of raising when the conflicting active row's credentials cannot be decrypted" do
      user = insert(:user)

      # Undecryptable bytes stand in for a credential whose key is genuinely
      # gone (e.g. after a SECRET_KEY_BASE rotation). The reactivation check
      # only needs to know this row exists, never its credentials.
      insert(:calendar_integration,
        user: user,
        provider: "caldav",
        provider_account_id: "acct-1",
        is_active: true,
        username_encrypted: :crypto.strong_rand_bytes(40),
        password_encrypted: :crypto.strong_rand_bytes(40)
      )

      dormant =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          provider_account_id: "acct-1",
          is_active: false
        )

      assert {:error, :duplicate_account} = CalendarIntegrationQueries.toggle_active(dormant)
    end

    test "returns {:error, :duplicate_account} for a legacy null-account row whose conflicting active row can't be decrypted" do
      user = insert(:user)

      insert(:calendar_integration,
        user: user,
        provider: "caldav",
        provider_account_id: nil,
        is_active: true,
        username_encrypted: :crypto.strong_rand_bytes(40),
        password_encrypted: :crypto.strong_rand_bytes(40)
      )

      dormant =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          provider_account_id: nil,
          is_active: false
        )

      assert {:error, :duplicate_account} = CalendarIntegrationQueries.toggle_active(dormant)
    end
  end
end
