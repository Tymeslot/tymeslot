defmodule Tymeslot.Integrations.Calendar.Nextcloud.LoginTest do
  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Security.Encryption

  setup do
    %{user: insert(:user)}
  end

  describe "nextcloud_logins/1" do
    test "lists only the user's active Nextcloud calendar connections", %{user: user} do
      active = insert_nextcloud(user, name: "Team cloud")
      _inactive = insert_nextcloud(user, name: "Old cloud", is_active: false)
      _caldav = insert(:calendar_integration, user: user, provider: "caldav")
      _someone_elses = insert_nextcloud(insert(:user), name: "Not mine")

      assert Calendar.nextcloud_logins(user.id) == [%{id: active.id, name: "Team cloud"}]
    end
  end

  describe "nextcloud_login/2" do
    test "returns the server root, login name and password", %{user: user} do
      integration =
        insert_nextcloud(user,
          base_url: "https://example.com/nextcloud/remote.php/dav/calendars/olivia/personal/"
        )

      assert {:ok, login} = Calendar.nextcloud_login(integration.id, user.id)
      assert login.server_url == "https://example.com/nextcloud"
      assert login.username == "olivia"
      assert login.password == "Abcde-Fghij-Klmno-Pqrst-Uvwxy"
    end

    test "refuses another user's connection", %{user: user} do
      integration = insert_nextcloud(insert(:user))
      assert {:error, :not_found} = Calendar.nextcloud_login(integration.id, user.id)
    end

    test "refuses a calendar connection that is not Nextcloud", %{user: user} do
      integration = insert(:calendar_integration, user: user, provider: "caldav")
      assert {:error, :not_found} = Calendar.nextcloud_login(integration.id, user.id)
    end
  end

  defp insert_nextcloud(user, overrides \\ []) do
    insert(
      :calendar_integration,
      Keyword.merge(
        [
          user: user,
          provider: "nextcloud",
          base_url: "https://cloud.example.com/remote.php/dav",
          username_encrypted: Encryption.encrypt("olivia"),
          password_encrypted: Encryption.encrypt("Abcde-Fghij-Klmno-Pqrst-Uvwxy")
        ],
        overrides
      )
    )
  end
end
