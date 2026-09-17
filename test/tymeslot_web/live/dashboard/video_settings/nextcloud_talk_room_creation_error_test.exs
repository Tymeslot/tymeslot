defmodule TymeslotWeb.Dashboard.VideoSettings.NextcloudTalkRoomCreationErrorTest do
  @moduledoc """
  A Nextcloud Talk server that refuses the conversations a booking needs, as
  the dashboard shows it: the connect form refuses an account Talk announces it
  will refuse, and the integration's row explains a refusal recorded when a
  booking met it, with the fix, until rooms are created again.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :video
  @moduletag :integrations
  @moduletag :live

  import Mox
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Test
  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Security.Encryption

  setup :verify_on_exit!

  @server "https://cloud.example.com"
  @app_password "Abcde-Fghij-Klmno-Pqrst-Uvwxy"

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    _profile = insert(:profile, user: user)
    conn = conn |> Test.init_test_session(%{}) |> fetch_session() |> log_in_user(user)
    {:ok, conn: conn, user: user}
  end

  describe "a server refusing to create conversations" do
    test "refuses to connect an account that may not create conversations, saying how to allow it",
         %{conn: conn, user: user} do
      expect_capabilities("organiser", @app_password, %{"can-create" => false})

      view = open_talk_form(conn)

      view
      |> form("#nextcloud-talk-video-integration-form",
        integration: %{
          name: "Team Talk",
          base_url: @server,
          client_id: "organiser",
          client_secret: @app_password
        }
      )
      |> render_submit()

      assert has_element?(
               view,
               "#nextcloud-talk-video-integration-form [role='alert']",
               "allow the user's group to create conversations"
             )

      assert Video.list_integrations(user.id) == []
    end

    test "the integration's row explains a refusal recorded at room creation, with its fix", %{
      conn: conn,
      user: user
    } do
      integration = insert_talk_integration(user, room_creation_error: :password_required)

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")

      assert has_element?(
               view,
               "p.text-amber-700",
               "New bookings get no video link. Nextcloud Talk requires a password on public conversations"
             )

      assert render(view) =~ "turn off the password requirement for public conversations"
      assert has_element?(view, "span", "No video links")
      refute has_element?(view, "span", "Healthy")

      # The row stays editable and switchable: nothing asks for a reconnection.
      refute has_element?(
               view,
               "button[phx-click='reconnect_integration'][phx-value-id='#{integration.id}']"
             )
    end

    test "the integration's row shows no notice once rooms are created again", %{
      conn: conn,
      user: user
    } do
      insert_talk_integration(user)

      {:ok, view, html} = live(conn, ~p"/dashboard/integrations?tab=video")

      refute html =~ "New bookings get no video link"
      assert has_element?(view, "span", "Healthy")
    end

    test "a needed reconnection is explained before a recorded refusal", %{
      conn: conn,
      user: user
    } do
      insert_talk_integration(user,
        needs_reauth: true,
        sync_error:
          "Nextcloud refused the app password. Edit this integration and enter a new app password.",
        room_creation_error: :password_required
      )

      {:ok, _view, html} = live(conn, ~p"/dashboard/integrations?tab=video")

      assert html =~ "Nextcloud refused the app password."
      refute html =~ "New bookings get no video link"
    end
  end

  defp open_talk_form(conn) do
    {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")

    view
    |> element("button[phx-click='setup_provider'][phx-value-provider='nextcloud_talk']")
    |> render_click()

    view
  end

  defp insert_talk_integration(user, overrides \\ []) do
    insert(
      :video_integration,
      Keyword.merge(
        [
          user: user,
          name: "Team Talk",
          provider: "nextcloud_talk",
          base_url: @server,
          client_id_encrypted: Encryption.encrypt("organiser"),
          client_secret_encrypted: Encryption.encrypt(@app_password),
          provider_account_id: @server <> "||organiser"
        ],
        overrides
      )
    )
  end

  # A Talk 25.0.0 server's capabilities, with the account's conversation rights
  # as `conversations` changes them.
  defp expect_capabilities(login, app_password, conversations) do
    expect(HTTPClientMock, :request, fn :get, _url, _body, headers, _opts ->
      assert {"Authorization", "Basic " <> Base.encode64(login <> ":" <> app_password)} in headers

      body =
        Jason.encode!(%{
          "ocs" => %{
            "data" => %{
              "capabilities" => %{
                "spreed" => %{
                  "version" => "25.0.0",
                  "features" => ["conversation-creation-all"],
                  "config" => %{
                    "conversations" =>
                      Map.merge(
                        %{"can-create" => true, "force-passwords" => false},
                        conversations
                      )
                  }
                }
              }
            }
          }
        })

      {:ok, %Req.Response{status: 200, body: body}}
    end)
  end
end
