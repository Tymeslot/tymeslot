defmodule TymeslotWeb.Dashboard.VideoSettings.NextcloudTalkRoomCreationErrorTest do
  @moduledoc """
  A Nextcloud Talk server that refuses the conversations a booking needs, as
  the dashboard shows it: the integration's row explains a refusal recorded
  when a booking met it, with the fix, until rooms are created again.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :video
  @moduletag :integrations
  @moduletag :live

  import Mox
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Plug.Test
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
end
