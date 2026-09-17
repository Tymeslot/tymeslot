defmodule Tymeslot.Integrations.Video.NextcloudTalkSetupTest do
  @moduledoc """
  Creating and editing a Nextcloud Talk integration. Creation proves the
  server, login name and app password against the server before anything is
  saved. An edit keeps a blank app password, proves only a real change to the
  server, login or password, and only such a proven change of credential
  clears the reconnect flag a refused app password set.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :integrations

  import Mox

  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.Security.Encryption

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

    test "a refused app password leaves the stored one and the flag in place", %{user: user} do
      integration = insert_talk_integration(user, needs_reauth: true)

      expect(HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 401, body: ""}}
      end)

      assert {:error, {:unauthorized, _message}} =
               Video.update_integration(user.id, integration.id, dialog_attrs("Wrong"))

      assert {:ok, %{client_secret: @app_password, needs_reauth: true}} =
               VideoIntegrationQueries.get_for_user(integration.id, user.id)
    end

    test "a new server address is proven with the stored credentials and moves the account key",
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
                 dialog_attrs("")
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

      assert {:ok, updated} =
               Video.update_integration(user.id, integration.id, %{
                 dialog_attrs("")
                 | name: "Renamed Talk"
               })

      assert updated.name == "Renamed Talk"
      assert updated.needs_reauth

      assert {:ok, %{client_secret: @app_password}} =
               VideoIntegrationQueries.get_for_user(integration.id, user.id)
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
    insert(:video_integration,
      user: user,
      name: "Team Talk",
      provider: "nextcloud_talk",
      base_url: @server,
      client_id_encrypted: Encryption.encrypt("organiser"),
      client_secret_encrypted:
        Encryption.encrypt(Keyword.get(overrides, :client_secret, @app_password)),
      provider_account_id: @server <> "||organiser",
      needs_reauth: Keyword.get(overrides, :needs_reauth, false)
    )
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
