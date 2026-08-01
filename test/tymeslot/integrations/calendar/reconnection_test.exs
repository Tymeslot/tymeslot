defmodule Tymeslot.Integrations.Calendar.ReconnectionTest do
  use Tymeslot.DataCase, async: true

  @moduletag :integrations
  @moduletag :calendar

  alias Tymeslot.Factory
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Reconnection
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption

  describe "credentials_change_kind/2" do
    setup do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "caldav",
          base_url: "https://caldav.example.com",
          provider_account_id: "https://caldav.example.com||alice",
          calendar_paths: ["/calendars/alice/default/"],
          is_active: true,
          username_encrypted: Encryption.encrypt("alice"),
          password_encrypted: Encryption.encrypt("oldpass")
        )

      decrypted = CalendarIntegrationSchema.decrypt_credentials(integration)
      %{integration: decrypted}
    end

    test "returns :password_only when url and username are unchanged", %{
      integration: integration
    } do
      params = %{
        "url" => "https://caldav.example.com",
        "username" => "alice",
        "password" => "newpass"
      }

      assert Reconnection.credentials_change_kind(integration, params) == :password_only
    end

    test "returns :account_change when url differs", %{integration: integration} do
      params = %{
        "url" => "https://caldav.other.example.com",
        "username" => "alice",
        "password" => "newpass"
      }

      assert Reconnection.credentials_change_kind(integration, params) == :account_change
    end

    test "returns :account_change when username differs", %{integration: integration} do
      params = %{
        "url" => "https://caldav.example.com",
        "username" => "bob",
        "password" => "newpass"
      }

      assert Reconnection.credentials_change_kind(integration, params) == :account_change
    end

    test "normalises trailing slash on url when comparing", %{integration: integration} do
      params = %{
        "url" => "https://caldav.example.com/",
        "username" => "alice",
        "password" => "newpass"
      }

      assert Reconnection.credentials_change_kind(integration, params) == :password_only
    end

    test "treats a nil url as an account change without crashing", %{integration: integration} do
      params = %{"url" => nil, "username" => "alice", "password" => "newpass"}

      assert Reconnection.credentials_change_kind(integration, params) == :account_change
    end
  end

  describe "reconnect/3" do
    setup do
      integration = insert_decrypted_caldav_integration(%{needs_reauth: true})
      %{integration: integration}
    end

    test "same credentials: returns :needs_calendar_selection so caller can add more calendars",
         %{integration: integration} do
      # Bug fix: previously `:password_only` short-circuited straight to a
      # save, hiding the calendar picker. Users with partial selections then
      # had no way to add the unselected ones without deleting the
      # integration. Reconnect now always surfaces the full calendar list.
      params = %{
        "url" => "https://caldav.example.com",
        "username" => "alice",
        "password" => "newpass"
      }

      discover = fn _provider, _url, _username, _password ->
        {:ok,
         %{
           calendars: [
             %{
               "id" => "/calendars/alice/default/",
               "path" => "/calendars/alice/default/",
               "name" => "Default",
               "type" => "calendar"
             },
             %{
               "id" => "/calendars/alice/work/",
               "path" => "/calendars/alice/work/",
               "name" => "Work",
               "type" => "calendar"
             }
           ],
           discovery_credentials: %{
             url: "https://caldav.example.com",
             username: "alice",
             password: "newpass"
           }
         }}
      end

      assert {:ok, :needs_calendar_selection, payload} =
               Reconnection.reconnect(integration, params, discover: discover)

      assert Enum.map(payload.calendars, & &1["path"]) == [
               "/calendars/alice/default/",
               "/calendars/alice/work/"
             ]

      assert payload.credentials.url == "https://caldav.example.com"
      assert payload.credentials.username == "alice"

      # The DB record is untouched until the caller calls
      # finalise_account_change/3 with the user's picks.
      reloaded = Repo.get!(CalendarIntegrationSchema, integration.id)
      assert reloaded.needs_reauth == true
    end

    test "url change: returns :needs_calendar_selection with discovered calendars", %{
      integration: integration
    } do
      params = %{
        "url" => "https://caldav.new.example.com",
        "username" => "alice",
        "password" => "newpass"
      }

      discover = fn _provider, _url, _username, _password ->
        {:ok,
         %{
           calendars: [
             %{
               "id" => "/new-path/",
               "path" => "/new-path/",
               "name" => "Home",
               "type" => "calendar"
             }
           ],
           discovery_credentials: %{
             url: "https://caldav.new.example.com",
             username: "alice",
             password: "newpass"
           }
         }}
      end

      assert {:ok, :needs_calendar_selection, payload} =
               Reconnection.reconnect(integration, params, discover: discover)

      assert [%{"path" => "/new-path/"}] = payload.calendars
      assert payload.credentials.url == "https://caldav.new.example.com"
    end

    test "discovery failure: propagates the discovery error", %{integration: integration} do
      params = %{
        "url" => "https://caldav.new.example.com",
        "username" => "alice",
        "password" => "newpass"
      }

      discover_fail = fn _provider, _url, _username, _password -> {:error, :timeout} end

      assert {:error, :timeout} =
               Reconnection.reconnect(integration, params, discover: discover_fail)
    end

    test "auth-style discovery error maps to :invalid_credentials", %{integration: integration} do
      # `Calendar.discover_and_filter_calendars/5` surfaces failures as
      # `{category, message}`, the category having been derived from the raw
      # provider error before the message was localised. Reconnection must
      # turn the `:auth` category into `:invalid_credentials` so the modal can
      # show a credentials-style error rather than a generic "something went
      # wrong" message.
      params = %{
        "url" => "https://caldav.example.com",
        "username" => "alice",
        "password" => "wrongpass"
      }

      discover_auth_fail = fn _provider, _url, _username, _password ->
        {:error, {:auth, "Authentication failed for CalDAV server."}}
      end

      assert {:error, :invalid_credentials} =
               Reconnection.reconnect(integration, params, discover: discover_auth_fail)

      reloaded = Repo.get!(CalendarIntegrationSchema, integration.id)
      assert reloaded.needs_reauth == true
    end

    test "auth mapping ignores the message wording", %{integration: integration} do
      # Regression: classification used to be re-derived by matching English
      # keywords against the message, so a translated message silently fell
      # through to the generic branch. The message below carries no English
      # keyword at all; only the category may be consulted.
      params = %{
        "url" => "https://caldav.example.com",
        "username" => "alice",
        "password" => "wrongpass"
      }

      discover_auth_fail = fn _provider, _url, _username, _password ->
        {:error, {:auth, "Authentifizierung für CalDAV-Server fehlgeschlagen."}}
      end

      assert {:error, :invalid_credentials} =
               Reconnection.reconnect(integration, params, discover: discover_auth_fail)
    end

    test "non-auth discovery error surfaces its message", %{integration: integration} do
      params = %{
        "url" => "https://caldav.example.com",
        "username" => "alice",
        "password" => "newpass"
      }

      discover_fail = fn _provider, _url, _username, _password ->
        {:error, {:network, "Zeitüberschreitung der Verbindung."}}
      end

      assert {:error, "Zeitüberschreitung der Verbindung."} =
               Reconnection.reconnect(integration, params, discover: discover_fail)
    end

    test "passes the integration's provider through to discover for non-caldav providers" do
      integration =
        insert_decrypted_caldav_integration(%{
          provider: "nextcloud",
          base_url: "https://cloud.example.com/remote.php/dav"
        })

      params = %{
        "url" => "https://new.cloud.example.com/remote.php/dav",
        "username" => "alice",
        "password" => "newpass"
      }

      test_pid = self()

      discover = fn provider, _url, _username, _password ->
        send(test_pid, {:discover_called_with, provider})

        {:ok,
         %{
           calendars: [
             %{"id" => "/c/", "path" => "/c/", "name" => "C", "type" => "calendar"}
           ],
           discovery_credentials: %{
             url: "https://new.cloud.example.com/remote.php/dav",
             username: "alice",
             password: "newpass"
           }
         }}
      end

      assert {:ok, :needs_calendar_selection, _payload} =
               Reconnection.reconnect(integration, params, discover: discover)

      assert_received {:discover_called_with, "nextcloud"}
    end
  end

  describe "finalise_account_change/3" do
    setup do
      integration = insert_decrypted_caldav_integration(%{})
      %{integration: integration}
    end

    test "persists new credentials and marks selected calendars", %{integration: integration} do
      payload = %{
        credentials: %{
          url: "https://caldav.new.example.com",
          username: "bob",
          password: "bobpass"
        },
        calendars: [
          %{"id" => "/a/", "path" => "/a/", "name" => "A", "type" => "calendar"},
          %{"id" => "/b/", "path" => "/b/", "name" => "B", "type" => "calendar"}
        ]
      }

      selected = ["/a/"]

      assert {:ok, updated} = Reconnection.finalise_account_change(integration, payload, selected)

      reloaded =
        CalendarIntegrationSchema
        |> Repo.get!(updated.id)
        |> CalendarIntegrationSchema.decrypt_credentials()

      assert reloaded.base_url == "https://caldav.new.example.com"
      assert reloaded.username == "bob"
      assert reloaded.calendar_paths == ["/a/"]
      assert Enum.find(reloaded.calendar_list, &(&1.path == "/a/")).selected == true
      assert Enum.find(reloaded.calendar_list, &(&1.path == "/b/")).selected == false
    end
  end

  defp insert_decrypted_caldav_integration(overrides) do
    {plaintext_username, overrides} = Map.pop(overrides, :username, "alice")
    {plaintext_password, overrides} = Map.pop(overrides, :password, "oldpass")

    base_attrs = %{
      provider: "caldav",
      base_url: "https://caldav.example.com",
      username_encrypted: Encryption.encrypt(plaintext_username),
      password_encrypted: Encryption.encrypt(plaintext_password),
      calendar_paths: ["/calendars/alice/default/"],
      calendar_list: [
        %{
          "id" => "/calendars/alice/default/",
          "path" => "/calendars/alice/default/",
          "name" => "Default",
          "type" => "calendar",
          "selected" => true
        }
      ],
      provider_account_id: "https://caldav.example.com||alice",
      is_active: true
    }

    attrs = Map.merge(base_attrs, overrides)

    :calendar_integration
    |> Factory.insert(attrs)
    |> CalendarIntegrationSchema.decrypt_credentials()
  end
end
