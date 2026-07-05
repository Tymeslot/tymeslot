defmodule TymeslotWeb.Dashboard.VideoSettingsComponentTest do
  use TymeslotWeb.LiveCase, async: true
  @moduletag :utils

  import Mox
  import Tymeslot.Factory
  import Tymeslot.AuthTestHelpers
  import Tymeslot.TestHelpers.Eventually

  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Repo

  alias Plug.Test

  setup :verify_on_exit!

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    _profile = insert(:profile, user: user)
    conn = conn |> Test.init_test_session(%{}) |> fetch_session()
    conn = log_in_user(conn, user)
    {:ok, conn: conn, user: user}
  end

  describe "Video Settings Component" do
    test "renders initial view with available providers", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")

      assert render(view) =~ "Video Integration"
      assert render(view) =~ "Available Providers"
      assert render(view) =~ "Connect Google Meet"
      assert render(view) =~ "Connect Teams"
      assert render(view) =~ "Connect Zoom"
      assert render(view) =~ "Connect MiroTalk"
      assert render(view) =~ "Add Custom Link"
    end

    test "renders Connect Zoom card on the providers grid", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/integrations?tab=video")

      assert html =~ "Connect Zoom"
      assert html =~ ~s(phx-value-provider="zoom")
    end

    test "shows a prompt when no video provider is connected", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/integrations?tab=video")

      assert html =~ "You haven&#39;t connected a video provider yet"
    end

    test "hides the prompt once a video provider is connected", %{conn: conn, user: user} do
      insert(:video_integration, user: user, is_active: true)

      {:ok, _view, html} = live(conn, ~p"/dashboard/integrations?tab=video")

      refute html =~ "You haven&#39;t connected a video provider yet"
    end

    test "lists connected integrations", %{conn: conn, user: user} do
      insert(:video_integration, user: user, name: "My MiroTalk", provider: "mirotalk")

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")

      assert render(view) =~ "My MiroTalk"
      # The provider-type tag renders in the collapsed connection row header.
      assert render(view) =~ "self-hosted"
    end

    test "toggles integration status", %{conn: conn, user: user} do
      integration = insert(:video_integration, user: user, is_active: true)

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")

      view
      |> element("#toggle-#{integration.id}")
      |> render_click()

      assert render(view) =~ "Integration status updated"
      refute Repo.get!(VideoIntegrationSchema, integration.id).is_active
    end

    test "tests connection for an integration", %{conn: conn, user: user} do
      integration = insert(:video_integration, user: user, provider: "mirotalk", is_active: true)

      stub(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: "{}"}}
      end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")

      # Actions live behind the expand chevron in the connection row.
      view
      |> element("button[phx-click='toggle_row'][phx-value-id='#{integration.id}']")
      |> render_click()

      view
      |> element("button[phx-click='test_connection'][phx-value-id='#{integration.id}']")
      |> render_click()

      eventually(fn ->
        assert render(view) =~ "MiroTalk connection verified"
      end)
    end

    test "navigates to setup form for mirotalk", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")

      view
      |> element("button", "Connect MiroTalk")
      |> render_click()

      assert render(view) =~ "Setup MiroTalk"
      assert has_element?(view, "input[name='integration[base_url]']")
    end

    test "adds a new mirotalk integration", %{conn: conn} do
      # Mock connection test for creation
      stub(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: "{}"}}
      end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")

      view
      |> element("button", "Connect MiroTalk")
      |> render_click()

      view
      |> form("#mirotalk-config-modal form", %{
        "integration" => %{
          "name" => "New MiroTalk",
          "base_url" => "https://miro.test",
          "api_key" => "secret-key-long-enough"
        }
      })
      |> render_submit()

      assert render(view) =~ "Video integration added successfully"
      assert render(view) =~ "New MiroTalk"
    end

    test "shows validation errors when adding integration", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")

      view
      |> element("button", "Connect MiroTalk")
      |> render_click()

      view
      |> form("#mirotalk-config-modal form", %{
        "integration" => %{
          "name" => "",
          "base_url" => "not-a-url",
          "api_key" => ""
        }
      })
      |> render_submit()

      assert render(view) =~ "Integration name is required"
    end

    test "initiates google meet oauth", %{conn: conn} do
      expect(Tymeslot.GoogleOAuthHelperMock, :authorization_url, fn _uid, _uri, _scopes ->
        "https://accounts.google.com/o/oauth2/v2/auth"
      end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")

      view
      |> element("button", "Connect Google Meet")
      |> render_click()

      # LiveView test follows redirects
      assert_redirect(view, "https://accounts.google.com/o/oauth2/v2/auth")
    end

    test "shows the collapsed-header Reconnect affordance for an OAuth integration needing reauth",
         %{conn: conn, user: user} do
      integration =
        insert(:video_integration,
          user: user,
          provider: "google_meet",
          is_active: true,
          needs_reauth: true
        )

      {:ok, view, html} = live(conn, ~p"/dashboard/integrations?tab=video")

      assert html =~ "Reconnect"

      assert has_element?(
               view,
               "button[phx-click='reconnect_integration'][phx-value-id='#{integration.id}']"
             )
    end

    test "does not show the Reconnect affordance for a non-OAuth provider", %{
      conn: conn,
      user: user
    } do
      integration =
        insert(:video_integration,
          user: user,
          provider: "mirotalk",
          is_active: true,
          needs_reauth: true
        )

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")

      refute has_element?(
               view,
               "button[phx-click='reconnect_integration'][phx-value-id='#{integration.id}']"
             )
    end

    # NOTE: the end-to-end click → OAuth-redirect for a *reconnect* is not
    # asserted here. `Video.oauth_reconnect_url/2` calls the google helper's
    # `authorization_url/4` (scopes + opts), but the injected test double
    # `GoogleOAuthHelperMock` is generated from `Calendar.Auth.OAuthHelperBehaviour`,
    # which only declares arity 2/3 — so `/4` cannot be stubbed, and widening the
    # behaviour would break the other implementers under --warnings-as-errors. The
    # reconnect button's presence and `reconnect_integration` wiring are covered by
    # the "collapsed-header Reconnect affordance" test above; the click → helper →
    # redirect mechanism itself is covered by "initiates google meet oauth".

    test "deletes an integration", %{conn: conn, user: user} do
      integration = insert(:video_integration, user: user, name: "To Delete")

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")

      assert render(view) =~ "To Delete"

      # Expand the row to reveal its actions, then open the delete modal.
      view
      |> element("button[phx-click='toggle_row'][phx-value-id='#{integration.id}']")
      |> render_click()

      view
      |> element(
        "button[phx-click='show'][phx-value-id='#{integration.id}'][phx-target='#delete-video-modal']"
      )
      |> render_click()

      # Confirm delete in modal
      view
      |> element("button", "Delete Integration")
      |> render_click()

      assert render(view) =~ "Integration deleted successfully"
      refute render(view) =~ "To Delete"
      assert Repo.get(VideoIntegrationSchema, integration.id) == nil
    end
  end
end
