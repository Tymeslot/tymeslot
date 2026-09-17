defmodule Tymeslot.Integrations.Video.NextcloudTalkSetupTest do
  @moduledoc """
  Creating and editing a Nextcloud Talk integration. Creation proves the
  server, login name and app password against the server before anything is
  saved. An edit keeps a blank app password, proves only a real change to the
  server, login or password, and only such a proven change of credential
  clears the reconnect flag a refused app password set.
  """

  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :integrations

  import Mox

  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Workers.VideoSyncWorker

  setup :verify_on_exit!

  @server "https://cloud.example.com"
  @app_password "Abcde-Fghij-Klmno-Pqrst-Uvwxy"

  setup do
    %{user: insert(:user)}
  end

  describe "create_integration/3" do
    test "proves the app password and stores the account keyed on server and login", %{
      user: user
    } do
      expect_capabilities(@server, "organiser", @app_password, talk_capabilities())

      assert {:ok, integration} =
               Video.create_integration(user.id, :nextcloud_talk, %{
                 name: "Team Talk",
                 base_url: @server <> "/",
                 client_id: " organiser ",
                 client_secret: @app_password
               })

      assert integration.provider == "nextcloud_talk"
      assert integration.base_url == @server
      assert integration.provider_account_id == @server <> "||organiser"

      assert {:ok, stored} = VideoIntegrationQueries.get_for_user(integration.id, user.id)
      assert stored.client_id == "organiser"
      assert stored.client_secret == @app_password
    end

    test "refuses the same account twice without contacting the server", %{user: user} do
      insert_talk_integration(user)

      assert {:error, :duplicate_integration} =
               Video.create_integration(user.id, :nextcloud_talk, %{
                 name: "Again",
                 base_url: @server <> "/",
                 client_id: "organiser",
                 client_secret: @app_password
               })
    end

    test "refuses the same account written with a capitalised host and its default port", %{
      user: user
    } do
      insert_talk_integration(user)

      assert {:error, :duplicate_integration} =
               Video.create_integration(user.id, :nextcloud_talk, %{
                 name: "Again",
                 base_url: "https://Cloud.Example.com:443",
                 client_id: "organiser",
                 client_secret: @app_password
               })
    end

    test "proves and saves the app password without the spaces around it", %{user: user} do
      expect_capabilities(@server, "organiser", @app_password, talk_capabilities())

      assert {:ok, integration} =
               Video.create_integration(user.id, :nextcloud_talk, %{
                 name: "Team Talk",
                 base_url: @server,
                 client_id: "organiser",
                 client_secret: " " <> @app_password <> " "
               })

      assert {:ok, %{client_secret: @app_password}} =
               VideoIntegrationQueries.get_for_user(integration.id, user.id)
    end

    test "refuses a missing app password without contacting the server", %{user: user} do
      assert {:error, "App password is required"} =
               Video.create_integration(user.id, :nextcloud_talk, %{
                 name: "Team Talk",
                 base_url: @server,
                 client_id: "organiser",
                 client_secret: ""
               })

      assert Video.list_integrations(user.id) == []
    end

    test "saves nothing when Nextcloud refuses the app password", %{user: user} do
      expect(HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 401, body: ""}}
      end)

      assert {:error, {:unauthorized, message}} =
               Video.create_integration(user.id, :nextcloud_talk, %{
                 name: "Team Talk",
                 base_url: @server,
                 client_id: "organiser",
                 client_secret: "Login-Password"
               })

      assert message =~ "app password"
      assert Video.list_integrations(user.id) == []
    end

    test "saves nothing when the server's Talk is too old", %{user: user} do
      expect_capabilities(@server, "organiser", @app_password, talk_capabilities(["chat-v2"]))

      assert {:error, {:unreachable, message}} =
               Video.create_integration(user.id, :nextcloud_talk, %{
                 name: "Team Talk",
                 base_url: @server,
                 client_id: "organiser",
                 client_secret: @app_password
               })

      assert message =~ "21.1"
      assert Video.list_integrations(user.id) == []
    end
  end

  describe "update_integration/3" do
    test "a new app password is proven and clears the reconnect flag", %{user: user} do
      integration = insert_talk_integration(user, needs_reauth: true, client_secret: "Revoked")
      expect_capabilities(@server, "organiser", "New-App-Password", talk_capabilities())

      assert {:ok, updated} =
               Video.update_integration(user.id, integration.id, dialog_attrs("New-App-Password"))

      refute updated.needs_reauth

      assert {:ok, %{client_secret: "New-App-Password"}} =
               VideoIntegrationQueries.get_for_user(integration.id, user.id)
    end

    test "a proven edit clears a recorded room creation refusal", %{user: user} do
      integration = insert_talk_integration(user)
      VideoIntegrationQueries.record_room_creation_error(integration.id, :password_required)
      expect_capabilities(@server, "organiser", "New-App-Password", talk_capabilities())

      assert {:ok, updated} =
               Video.update_integration(user.id, integration.id, dialog_attrs("New-App-Password"))

      assert %{room_creation_error: nil, room_creation_error_since: nil} = updated

      assert {:ok, %{room_creation_error: nil}} =
               VideoIntegrationQueries.get_for_user(integration.id, user.id)
    end

    test "a rename keeps a recorded room creation refusal", %{user: user} do
      integration = insert_talk_integration(user)
      VideoIntegrationQueries.record_room_creation_error(integration.id, :password_required)

      assert {:ok, _renamed} =
               Video.update_integration(user.id, integration.id, %{name: "Renamed"})

      assert {:ok, %{room_creation_error: :password_required}} =
               VideoIntegrationQueries.get_for_user(integration.id, user.id)
    end

    # Reschedules made while the app password was refused never reached their
    # conversations, so the proven reconnect sends every upcoming one its
    # current time again. Ended and cancelled meetings are the clean-up's.
    test "a proven reconnect queues a room update for each upcoming meeting", %{user: user} do
      integration = insert_talk_integration(user, needs_reauth: true, client_secret: "Revoked")
      upcoming = insert_meeting_with_room(integration, 2)
      running = insert_meeting_with_room(integration, 0)
      insert_meeting_with_room(integration, -2)
      insert_meeting_with_room(integration, 3, status: "cancelled")

      insert_meeting_with_room(
        insert_talk_integration(user, base_url: "https://b.example.com"),
        4
      )

      expect_capabilities(@server, "organiser", "New-App-Password", talk_capabilities())

      assert {:ok, _updated} =
               Video.update_integration(user.id, integration.id, dialog_attrs("New-App-Password"))

      assert queued_room_updates() == Enum.sort([upcoming.id, running.id])
    end

    test "a proven new app password on a connected integration queues no room update", %{
      user: user
    } do
      integration = insert_talk_integration(user, client_secret: "Old")
      insert_meeting_with_room(integration, 2)
      expect_capabilities(@server, "organiser", "New-App-Password", talk_capabilities())

      assert {:ok, _updated} =
               Video.update_integration(user.id, integration.id, dialog_attrs("New-App-Password"))

      assert queued_room_updates() == []
    end

    test "a refused app password leaves the stored one and the flag in place", %{user: user} do
      integration = insert_talk_integration(user, needs_reauth: true)
      insert_meeting_with_room(integration, 2)

      expect(HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 401, body: ""}}
      end)

      assert {:error, {:unauthorized, _message}} =
               Video.update_integration(user.id, integration.id, dialog_attrs("Wrong"))

      assert {:ok, %{client_secret: @app_password, needs_reauth: true}} =
               VideoIntegrationQueries.get_for_user(integration.id, user.id)

      assert queued_room_updates() == []
    end

    test "a refused new app password leaves an unflagged integration unflagged", %{user: user} do
      integration = insert_talk_integration(user)

      expect(HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 401, body: ""}}
      end)

      assert {:error, {:unauthorized, _message}} =
               Video.update_integration(user.id, integration.id, dialog_attrs("Wrong"))

      assert {:ok, %{client_secret: @app_password, needs_reauth: false}} =
               VideoIntegrationQueries.get_for_user(integration.id, user.id)
    end

    test "a new app password is proven and saved without the spaces around it", %{user: user} do
      integration = insert_talk_integration(user, client_secret: "Revoked")
      expect_capabilities(@server, "organiser", "New-App-Password", talk_capabilities())

      assert {:ok, _updated} =
               Video.update_integration(
                 user.id,
                 integration.id,
                 dialog_attrs(" New-App-Password ")
               )

      assert {:ok, %{client_secret: "New-App-Password"}} =
               VideoIntegrationQueries.get_for_user(integration.id, user.id)
    end

    test "an app password that is not text is refused without contacting the server", %{
      user: user
    } do
      integration = insert_talk_integration(user)

      assert {:error, "App password is required"} =
               Video.update_integration(user.id, integration.id, %{
                 dialog_attrs("")
                 | client_secret: 12_345
               })
    end

    # Nextcloud moved to a new address: the old host refuses the app password,
    # the organiser enters the new server with the app password again, and the
    # server proves it. That proof is the reconnect.
    test "a proven new server address clears the reconnect flag", %{user: user} do
      integration = insert_talk_integration(user, needs_reauth: true)

      expect_capabilities(
        "https://talk.example.org",
        "organiser",
        @app_password,
        talk_capabilities()
      )

      assert {:ok, updated} =
               Video.update_integration(user.id, integration.id, %{
                 dialog_attrs(@app_password)
                 | base_url: "https://talk.example.org"
               })

      refute updated.needs_reauth
      assert updated.base_url == "https://talk.example.org"
    end

    # The stored app password may have been copied from a calendar connection,
    # so it is never sent to a different server unless it is entered again.
    for {label, new_server} <- [
          {"host", "https://talk.example.org"},
          {"port", "https://cloud.example.com:8443"}
        ] do
      test "a new server #{label} without the app password is refused without contacting either server",
           %{user: user} do
        integration = insert_talk_integration(user, needs_reauth: true)

        assert {:error, {:secret_required, message}} =
                 Video.update_integration(user.id, integration.id, %{
                   dialog_attrs("")
                   | base_url: unquote(new_server)
                 })

        assert message =~ "Enter the app password again"

        assert {:ok, %{base_url: @server, client_secret: @app_password, needs_reauth: true}} =
                 VideoIntegrationQueries.get_for_user(integration.id, user.id)
      end
    end

    test "a new subfolder on the same server keeps the stored app password and is proven", %{
      user: user
    } do
      integration = insert_talk_integration(user)

      expect_capabilities(
        @server <> "/nextcloud",
        "organiser",
        @app_password,
        talk_capabilities()
      )

      assert {:ok, updated} =
               Video.update_integration(user.id, integration.id, %{
                 dialog_attrs("")
                 | base_url: "https://CLOUD.example.com:443/nextcloud/"
               })

      assert updated.base_url == @server <> "/nextcloud"
    end

    test "a server and login already connected in another integration are refused without contacting the server",
         %{user: user} do
      integration = insert_talk_integration(user)

      insert_talk_integration(user,
        base_url: "https://talk.example.org",
        is_active: false
      )

      assert {:error, :duplicate_integration} =
               Video.update_integration(user.id, integration.id, %{
                 dialog_attrs(@app_password)
                 | base_url: "https://Talk.example.org/"
               })

      assert {:ok, %{base_url: @server}} =
               VideoIntegrationQueries.get_for_user(integration.id, user.id)
    end

    test "a submitted account key is ignored", %{user: user} do
      integration = insert_talk_integration(user)

      assert {:ok, updated} =
               Video.update_integration(user.id, integration.id, %{
                 name: "Renamed",
                 provider_account_id: "https://elsewhere.example.com||someone"
               })

      assert updated.provider_account_id == @server <> "||organiser"
    end

    test "a new server address is proven with the app password entered again and moves the account key",
         %{user: user} do
      integration = insert_talk_integration(user)

      expect_capabilities(
        "https://talk.example.org",
        "organiser",
        @app_password,
        talk_capabilities()
      )

      assert {:ok, updated} =
               Video.update_integration(user.id, integration.id, %{
                 dialog_attrs(@app_password)
                 | base_url: "https://talk.example.org/"
               })

      assert updated.base_url == "https://talk.example.org"
      assert updated.provider_account_id == "https://talk.example.org||organiser"
    end

    test "a new login name is proven, moves the account key and clears the flag", %{user: user} do
      integration = insert_talk_integration(user, needs_reauth: true)
      expect_capabilities(@server, "olivia", "New-App-Password", talk_capabilities())

      assert {:ok, updated} =
               Video.update_integration(user.id, integration.id, %{
                 dialog_attrs("New-App-Password")
                 | client_id: "olivia"
               })

      assert updated.provider_account_id == @server <> "||olivia"
      refute updated.needs_reauth

      assert {:ok, %{client_id: "olivia"}} =
               VideoIntegrationQueries.get_for_user(integration.id, user.id)
    end

    test "a blank app password keeps the stored one and makes no server call", %{user: user} do
      integration = insert_talk_integration(user, needs_reauth: true)
      insert_meeting_with_room(integration, 2)

      assert {:ok, updated} =
               Video.update_integration(user.id, integration.id, %{
                 dialog_attrs("")
                 | name: "Renamed Talk"
               })

      assert updated.name == "Renamed Talk"
      assert updated.needs_reauth

      assert {:ok, %{client_secret: @app_password}} =
               VideoIntegrationQueries.get_for_user(integration.id, user.id)

      assert queued_room_updates() == []
    end

    # The stored values, written the way a person might type them again: the
    # provider's own trimming makes them the same account, so nothing changed.
    test "the stored credentials resubmitted unchanged make no server call and keep the flag", %{
      user: user
    } do
      integration = insert_talk_integration(user, needs_reauth: true)

      assert {:ok, updated} =
               Video.update_integration(user.id, integration.id, %{
                 name: "Team Talk",
                 base_url: @server <> "/",
                 client_id: " organiser ",
                 client_secret: @app_password
               })

      assert updated.needs_reauth
      assert updated.provider_account_id == @server <> "||organiser"
    end

    test "a blank server address is refused without contacting the server", %{user: user} do
      integration = insert_talk_integration(user)

      assert {:error, "Base URL is required"} =
               Video.update_integration(user.id, integration.id, %{
                 dialog_attrs("")
                 | base_url: " "
               })

      assert {:ok, %{base_url: @server}} =
               VideoIntegrationQueries.get_for_user(integration.id, user.id)
    end

    test "a rename alone makes no server call", %{user: user} do
      integration = insert_talk_integration(user)

      assert {:ok, %{name: "Renamed"}} =
               Video.update_integration(user.id, integration.id, %{name: "Renamed"})
    end
  end

  # What the edit dialog submits: the server and login it opened with, and
  # whatever was typed into the app password field.
  defp dialog_attrs(app_password) do
    %{name: "Team Talk", base_url: @server, client_id: "organiser", client_secret: app_password}
  end

  defp insert_talk_integration(user, overrides \\ []) do
    server = Keyword.get(overrides, :base_url, @server)

    insert(:video_integration,
      user: user,
      name: "Team Talk",
      provider: "nextcloud_talk",
      base_url: server,
      client_id_encrypted: Encryption.encrypt("organiser"),
      client_secret_encrypted:
        Encryption.encrypt(Keyword.get(overrides, :client_secret, @app_password)),
      provider_account_id: server <> "||organiser",
      needs_reauth: Keyword.get(overrides, :needs_reauth, false),
      is_active: Keyword.get(overrides, :is_active, true)
    )
  end

  # A meeting holding a conversation of `integration`, starting `offset_days`
  # from now and lasting two hours, so one starting today is still running.
  defp insert_meeting_with_room(integration, offset_days, overrides \\ []) do
    start_time =
      DateTime.utc_now(:second) |> DateTime.add(offset_days, :day) |> DateTime.add(-1, :hour)

    insert(
      :meeting,
      Keyword.merge(
        [
          organizer_user_id: integration.user_id,
          video_integration_id: integration.id,
          video_provider: "nextcloud_talk",
          video_room_id: "room-#{System.unique_integer([:positive])}",
          start_time: start_time,
          end_time: DateTime.add(start_time, 2, :hour)
        ],
        overrides
      )
    )
  end

  defp queued_room_updates do
    [worker: VideoSyncWorker, args: %{"action" => "update"}]
    |> all_enqueued()
    |> Enum.map(& &1.args["meeting_id"])
    |> Enum.sort()
  end

  defp expect_capabilities(server, login, app_password, response) do
    expect(HTTPClientMock, :request, fn :get, url, "", headers, _opts ->
      assert url == server <> "/ocs/v2.php/cloud/capabilities"
      assert {"Authorization", "Basic " <> Base.encode64(login <> ":" <> app_password)} in headers
      response
    end)
  end

  defp talk_capabilities(features \\ ["conversation-creation-all"]) do
    body =
      Jason.encode!(%{
        "ocs" => %{
          "meta" => %{"status" => "ok"},
          "data" => %{
            "capabilities" => %{"spreed" => %{"version" => "25.0.0", "features" => features}}
          }
        }
      })

    {:ok, %Req.Response{status: 200, body: body}}
  end
end
