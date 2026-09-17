defmodule TymeslotWeb.Dashboard.VideoSettings.NextcloudTalkFormTest do
  @moduledoc """
  Connecting Nextcloud Talk from the dashboard: typing the credentials,
  copying them from a Nextcloud calendar connection without the password ever
  reaching the browser, and, in the edit dialog, keeping the stored app
  password when the field is left blank or entering a new one after Nextcloud
  refused the old one.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :video
  @moduletag :integrations
  @moduletag :live

  import Mox
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Plug.Test
  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption

  setup :verify_on_exit!

  @server "https://cloud.example.com"
  @app_password "Abcde-Fghij-Klmno-Pqrst-Uvwxy"
  @refused "Nextcloud refused the login name or app password"

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    _profile = insert(:profile, user: user)
    conn = conn |> Test.init_test_session(%{}) |> fetch_session() |> log_in_user(user)
    {:ok, conn: conn, user: user}
  end

  describe "connect form" do
    test "connects with a server, login name and app password", %{conn: conn, user: user} do
      expect_capabilities("organiser", @app_password)

      view = open_talk_form(conn)
      html = render(view)
      assert html =~ "Join from a browser signed in to Nextcloud as this login name"
      assert html =~ "about a week after the meeting ends"

      # A password manager must not take the pair for a sign-in to Tymeslot.
      assert has_element?(view, "#nextcloud_talk_client_id[autocomplete='off']")

      assert has_element?(
               view,
               "#nextcloud_talk_client_secret[type='password'][autocomplete='new-password']:not([value])"
             )

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

      assert render(view) =~ "Video integration added successfully"
      assert render(view) =~ "organiser · cloud.example.com · self-hosted"

      assert [%{provider: "nextcloud_talk", base_url: @server, client_id: "organiser"}] =
               Video.list_integrations(user.id)
    end

    test "shows a refused app password on the password field and saves nothing", %{
      conn: conn,
      user: user
    } do
      expect_status(401)

      view = open_talk_form(conn)

      view
      |> form("#nextcloud-talk-video-integration-form",
        integration: %{
          name: "Team Talk",
          base_url: @server,
          client_id: "organiser",
          client_secret: "Login-Password"
        }
      )
      |> render_submit()

      assert has_element?(
               view,
               "#nextcloud-talk-video-integration-form p.form-error",
               @refused
             )

      assert has_element?(view, "#nextcloud_talk_client_secret.input-error")
      assert Video.list_integrations(user.id) == []
    end

    test "asks for the app password without contacting the server", %{conn: conn, user: user} do
      html =
        conn
        |> open_talk_form()
        |> form("#nextcloud-talk-video-integration-form",
          integration: %{name: "Team Talk", base_url: @server, client_id: "organiser"}
        )
        |> render_submit()

      assert html =~ "App password is required"
      assert Video.list_integrations(user.id) == []
    end

    test "names an already connected Nextcloud account without contacting the server", %{
      conn: conn,
      user: user
    } do
      insert_talk_integration(user)

      html =
        conn
        |> open_talk_form()
        |> form("#nextcloud-talk-video-integration-form",
          integration: %{
            name: "Again",
            base_url: @server,
            client_id: "organiser",
            client_secret: @app_password
          }
        )
        |> render_submit()

      assert html =~ "This Nextcloud account is already connected"
      assert [%{name: "Team Talk"}] = Video.list_integrations(user.id)
    end

    test "copies a Nextcloud calendar connection without sending its password to the browser", %{
      conn: conn,
      user: user
    } do
      calendar = insert_nextcloud_calendar(user)
      view = open_talk_form(conn)

      html =
        view
        |> element("button[phx-click='copy_nextcloud_login'][phx-value-id='#{calendar.id}']")
        |> render_click()

      assert has_element?(view, "#nextcloud_talk_base_url[value='#{@server}']")
      assert has_element?(view, "#nextcloud_talk_client_id[value='olivia']")
      assert html =~ "Leave blank to use the app password of your calendar connection."
      refute html =~ @app_password

      assert has_element?(
               view,
               "[role='group'][aria-labelledby='nextcloud_talk_copy_heading'][aria-describedby='nextcloud_talk_copy_help'] button[phx-click='copy_nextcloud_login']"
             )

      assert has_element?(
               view,
               "#nextcloud_talk_copy_heading",
               "Use your Nextcloud calendar connection"
             )

      assert has_element?(view, "#nextcloud_talk_copy_help")

      expect_capabilities("olivia", @app_password)

      view
      |> form("#nextcloud-talk-video-integration-form", integration: %{name: "Team Talk"})
      |> render_submit()

      assert render(view) =~ "Video integration added successfully"

      assert [%{provider: "nextcloud_talk", client_id: "olivia", client_secret: @app_password}] =
               Video.list_integrations(user.id)
    end

    test "a typed app password wins over a copied calendar connection's", %{
      conn: conn,
      user: user
    } do
      calendar = insert_nextcloud_calendar(user)
      view = open_talk_form(conn)

      view
      |> element("button[phx-click='copy_nextcloud_login'][phx-value-id='#{calendar.id}']")
      |> render_click()

      expect_capabilities("olivia", "Typed-App-Password")

      view
      |> form("#nextcloud-talk-video-integration-form",
        integration: %{name: "Team Talk", client_secret: "Typed-App-Password"}
      )
      |> render_submit()

      assert [%{client_id: "olivia", client_secret: "Typed-App-Password"}] =
               Video.list_integrations(user.id)
    end

    test "uses a copied app password when the server and login differ only in spacing and a trailing slash",
         %{conn: conn, user: user} do
      view = copy_calendar_login(conn, insert_nextcloud_calendar(user))
      expect_capabilities("olivia", @app_password)

      view
      |> form("#nextcloud-talk-video-integration-form",
        integration: %{name: "Team Talk", base_url: " #{@server}/ ", client_id: " olivia "}
      )
      |> render_submit()

      assert [%{client_id: "olivia", client_secret: @app_password}] =
               Video.list_integrations(user.id)
    end

    test "adds no copied password when only the login name was changed", %{conn: conn, user: user} do
      view = copy_calendar_login(conn, insert_nextcloud_calendar(user))

      html =
        view
        |> form("#nextcloud-talk-video-integration-form",
          integration: %{name: "Team Talk", client_id: "someone-else"}
        )
        |> render_submit()

      assert html =~ "App password is required"
      assert Video.list_integrations(user.id) == []
    end

    for {label, change} <- [
          {"server", [base_url: "https://other.example.com/remote.php/dav"]},
          {"login name", [username_encrypted: Encryption.encrypt("someone-else")]}
        ] do
      test "adds no copied password when the calendar connection's #{label} changed after the copy",
           %{conn: conn, user: user} do
        calendar = insert_nextcloud_calendar(user)
        view = copy_calendar_login(conn, calendar)

        calendar |> Changeset.change(unquote(change)) |> Repo.update!()

        html =
          view
          |> form("#nextcloud-talk-video-integration-form", integration: %{name: "Team Talk"})
          |> render_submit()

        assert html =~ "App password is required"
        assert Video.list_integrations(user.id) == []
      end
    end

    test "says so when the copied calendar connection was deactivated before saving", %{
      conn: conn,
      user: user
    } do
      calendar = insert_nextcloud_calendar(user)
      view = copy_calendar_login(conn, calendar)

      calendar |> Changeset.change(is_active: false) |> Repo.update!()

      html =
        view
        |> form("#nextcloud-talk-video-integration-form", integration: %{name: "Team Talk"})
        |> render_submit()

      assert has_element?(
               view,
               "#nextcloud-talk-video-integration-form [role='alert']",
               "That calendar connection is no longer available."
             )

      refute html =~ "App password is required"
      refute html =~ "Leave blank to use the app password of your calendar connection."
      assert Video.list_integrations(user.id) == []
    end

    test "never sends a copied password to a server other than the calendar's", %{
      conn: conn,
      user: user
    } do
      calendar = insert_nextcloud_calendar(user)
      view = open_talk_form(conn)

      view
      |> element("button[phx-click='copy_nextcloud_login'][phx-value-id='#{calendar.id}']")
      |> render_click()

      changed = %{name: "Team Talk", base_url: "https://elsewhere.example.org"}

      refute view
             |> form("#nextcloud-talk-video-integration-form", integration: changed)
             |> render_change() =~
               "Leave blank to use the app password of your calendar connection."

      html =
        view
        |> form("#nextcloud-talk-video-integration-form", integration: changed)
        |> render_submit()

      assert html =~ "App password is required"
      assert Video.list_integrations(user.id) == []
    end

    test "offers no copy to a user without a Nextcloud calendar connection", %{conn: conn} do
      refute conn |> open_talk_form() |> has_element?("button[phx-click='copy_nextcloud_login']")
    end

    test "refuses to copy another user's Nextcloud calendar connection", %{conn: conn, user: user} do
      insert_nextcloud_calendar(user)
      others = insert_nextcloud_calendar(insert(:user))
      view = open_talk_form(conn)

      # The button offers the user's own connection; the id is swapped for
      # someone else's, as a crafted event would.
      html =
        view
        |> element("button[phx-click='copy_nextcloud_login']")
        |> render_click(%{"id" => to_string(others.id)})

      assert html =~ "That calendar connection is no longer available."
      refute has_element?(view, "#nextcloud_talk_client_id[value='olivia']")
    end
  end

  describe "edit dialog" do
    test "keeps the stored app password when the field is left blank, with no server call", %{
      conn: conn,
      user: user
    } do
      integration = insert_talk_integration(user)
      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")
      open_edit_dialog(view, integration)

      assert has_element?(view, "#edit_nextcloud_talk_base_url[value='#{@server}']")
      assert has_element?(view, "#edit_nextcloud_talk_client_id[value='organiser']")

      assert has_element?(
               view,
               "#edit_nextcloud_talk_client_secret[type='password']:not([value])"
             )

      assert render(view) =~ "Leave blank to keep the current app password."
      refute render(view) =~ @app_password

      view
      |> form("#edit-video-integration-form", integration: %{name: "Renamed Talk"})
      |> render_submit()

      assert render(view) =~ "Integration updated successfully"

      assert {:ok, %{name: "Renamed Talk", client_secret: @app_password}} =
               Video.get_integration(user.id, integration.id)
    end

    test "takes a new app password after Nextcloud refused the old one", %{
      conn: conn,
      user: user
    } do
      integration =
        insert_talk_integration(user,
          needs_reauth: true,
          sync_error:
            "Nextcloud refused the app password. Edit this integration and enter a new app password."
        )

      {:ok, view, html} = live(conn, ~p"/dashboard/integrations?tab=video")
      assert html =~ "Edit this integration and enter a new app password"

      open_edit_dialog(view, integration)
      expect_capabilities("organiser", "New-App-Password")

      view
      |> form("#edit-video-integration-form", integration: %{client_secret: "New-App-Password"})
      |> render_submit()

      assert render(view) =~ "Integration updated successfully"

      row = Repo.get!(VideoIntegrationSchema, integration.id)
      refute row.needs_reauth
      assert Encryption.decrypt(row.client_secret_encrypted) == "New-App-Password"
    end

    test "asks for the app password again before moving to a different server", %{
      conn: conn,
      user: user
    } do
      integration = insert_talk_integration(user)
      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")
      open_edit_dialog(view, integration)

      assert has_element?(
               view,
               "#edit_nextcloud_talk_client_secret[type='password'][autocomplete='new-password']"
             )

      view
      |> form("#edit-video-integration-form",
        integration: %{base_url: "https://talk.example.org"}
      )
      |> render_submit()

      assert has_element?(
               view,
               "#edit-video-integration-form p.form-error",
               "Enter the app password again"
             )

      assert has_element?(view, "#edit_nextcloud_talk_client_secret.input-error")

      assert {:ok, %{base_url: @server, client_secret: @app_password}} =
               Video.get_integration(user.id, integration.id)
    end

    test "shows the provider's own refusal of an edit in the dialog", %{conn: conn, user: user} do
      integration = insert_talk_integration(user)
      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")
      open_edit_dialog(view, integration)

      view
      |> form("#edit-video-integration-form", integration: %{base_url: " "})
      |> render_submit()

      assert has_element?(
               view,
               "#edit-video-integration-form [role='alert']",
               "Base URL is required"
             )

      assert {:ok, %{base_url: @server}} = Video.get_integration(user.id, integration.id)
    end

    test "shows Nextcloud's refusal of a new app password on the password field", %{
      conn: conn,
      user: user
    } do
      integration = insert_talk_integration(user)
      expect_status(401)

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")
      open_edit_dialog(view, integration)

      view
      |> form("#edit-video-integration-form", integration: %{client_secret: "Wrong-Password"})
      |> render_submit()

      assert has_element?(view, "#edit-video-integration-form p.form-error", @refused)
      assert has_element?(view, "#edit_nextcloud_talk_client_secret.input-error")
      refute render(view) =~ "Failed to update integration"

      assert {:ok, %{client_secret: @app_password}} =
               Video.get_integration(user.id, integration.id)
    end

    test "asks the organiser to wait when Nextcloud throttles the check of an edit", %{
      conn: conn,
      user: user
    } do
      integration = insert_talk_integration(user)
      expect_status(429)

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")
      open_edit_dialog(view, integration)

      view
      |> form("#edit-video-integration-form", integration: %{client_secret: "New-App-Password"})
      |> render_submit()

      assert has_element?(
               view,
               "#edit-video-integration-form [role='alert']",
               "Wait a few minutes before trying again."
             )

      refute has_element?(view, "#edit-video-integration-form p.form-error")
      refute render(view) =~ "Failed to update integration"

      assert {:ok, %{client_secret: @app_password}} =
               Video.get_integration(user.id, integration.id)
    end

    test "refuses to move an integration onto an account already connected", %{
      conn: conn,
      user: user
    } do
      integration = insert_talk_integration(user)

      insert_talk_integration(user,
        name: "Second Talk",
        client_id_encrypted: Encryption.encrypt("olivia"),
        provider_account_id: @server <> "||olivia"
      )

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")
      open_edit_dialog(view, integration)

      view
      |> form("#edit-video-integration-form", integration: %{client_id: "olivia"})
      |> render_submit()

      assert has_element?(
               view,
               "#edit-video-integration-form [role='alert']",
               "This Nextcloud account is already connected."
             )

      assert {:ok, %{client_id: "organiser"}} = Video.get_integration(user.id, integration.id)
    end
  end

  defp open_talk_form(conn) do
    {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")

    view
    |> element("button[phx-click='setup_provider'][phx-value-provider='nextcloud_talk']")
    |> render_click()

    view
  end

  defp copy_calendar_login(conn, calendar) do
    view = open_talk_form(conn)

    view
    |> element("button[phx-click='copy_nextcloud_login'][phx-value-id='#{calendar.id}']")
    |> render_click()

    view
  end

  defp open_edit_dialog(view, integration) do
    view
    |> element(
      "button[phx-click='show'][phx-value-id='#{integration.id}'][phx-target='#edit-video-modal']"
    )
    |> render_click()
  end

  defp insert_nextcloud_calendar(user) do
    insert(:calendar_integration,
      user: user,
      name: "Team cloud",
      provider: "nextcloud",
      base_url: @server <> "/remote.php/dav",
      username_encrypted: Encryption.encrypt("olivia"),
      password_encrypted: Encryption.encrypt(@app_password)
    )
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

  defp expect_status(status) do
    expect(HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
      {:ok, %Req.Response{status: status, body: ""}}
    end)
  end

  defp expect_capabilities(login, app_password) do
    expect(HTTPClientMock, :request, fn :get, _url, _body, headers, _opts ->
      assert {"Authorization", "Basic " <> Base.encode64(login <> ":" <> app_password)} in headers

      body =
        Jason.encode!(%{
          "ocs" => %{
            "data" => %{
              "capabilities" => %{
                "spreed" => %{"version" => "25.0.0", "features" => ["conversation-creation-all"]}
              }
            }
          }
        })

      {:ok, %Req.Response{status: 200, body: body}}
    end)
  end
end
