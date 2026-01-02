defmodule Tymeslot.DatabaseQueries.CalendarIntegrationQueriesTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :queries

  alias Tymeslot.DatabaseQueries.CalendarIntegrationQueries

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
        Repo.get(Tymeslot.DatabaseSchemas.CalendarIntegrationSchema, integration.id)

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
