defmodule TymeslotWeb.Dashboard.VideoSettingsComponentTest do
  use TymeslotWeb.LiveCase, async: true
  @moduletag :utils
  @moduletag :video

  import Mox
  import Tymeslot.Factory
  import Tymeslot.AuthTestHelpers

  alias Tymeslot.Integrations.Video
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
    test "renders initial view with the provider picker options", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/integrations?tab=video")

      assert html =~ "Video Integration"
      assert html =~ "Connect a video provider"

      # Each provider is a selectable option in the always-rendered picker modal.
      for provider <- ~w(google_meet teams zoom mirotalk custom) do
        assert html =~ ~s(phx-value-provider="#{provider}")
      end
    end

    test "groups the provider picker by hosting model", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/integrations?tab=video")

      document = Floki.parse_document!(html)

      headings =
        document |> Floki.find("h3") |> Enum.map(&(&1 |> Floki.text() |> String.trim()))

      assert "Hosted services" in headings
      assert "Self-hosted" in headings
      assert "Other" in headings

      groups =
        document
        # Each picker group renders as its own "space-y-3" div holding the
        # heading and the provider grid as siblings.
        |> Floki.find("div.space-y-3")
        |> Enum.filter(&(Floki.find(&1, "h3") != []))
        |> Map.new(fn group ->
          label = group |> Floki.find("h3") |> Floki.text() |> String.trim()

          providers =
            group
            |> Floki.find("[phx-value-provider]")
            |> Enum.map(&(&1 |> Floki.attribute("phx-value-provider") |> List.first()))

          {label, providers}
        end)

      assert groups["Hosted services"] == ~w(google_meet teams zoom kmeet)
      assert groups["Self-hosted"] == ~w(mirotalk jitsi)
      assert groups["Other"] == ~w(custom)
    end

    test "renders the Zoom option in the provider picker", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/integrations?tab=video")

      assert html =~ ~s(phx-click="setup_provider")
      assert html =~ ~s(phx-value-provider="zoom")
    end

    test "shows an empty state when no video provider is connected", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/integrations?tab=video")

      assert html =~ "No video providers connected yet"
    end

    test "hides the empty state once a video provider is connected", %{conn: conn, user: user} do
      insert(:video_integration, user: user, is_active: true)

      {:ok, _view, html} = live(conn, ~p"/dashboard/integrations?tab=video")

      refute html =~ "No video providers connected yet"
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

      view
      |> element("button[phx-click='test_connection'][phx-value-id='#{integration.id}']")
      |> render_click()

      # The probe runs in a `start_async` task whose result reaches the parent
      # LiveView as a flash message. Waiting on the task rather than polling
      # for a fixed second keeps this green on a loaded machine, and the
      # `render/1` after it is queued behind that flash message.
      render_async(view, 10_000)
      assert render(view) =~ "MiroTalk connection verified"
    end

    test "navigates to setup form for mirotalk", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")

      view
      |> element("button[phx-click='setup_provider'][phx-value-provider='mirotalk']")
      |> render_click()

      assert render(view) =~ "MiroTalk P2P"
      assert has_element?(view, "input[name='integration[base_url]']")
    end

    test "adds a new mirotalk integration", %{conn: conn} do
      # Mock connection test for creation
      stub(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: "{}"}}
      end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")

      view
      |> element("button[phx-click='setup_provider'][phx-value-provider='mirotalk']")
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
      |> element("button[phx-click='setup_provider'][phx-value-provider='mirotalk']")
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

    test "shows a message when adding a duplicate custom video integration", %{
      conn: conn,
      user: user
    } do
      insert(:video_integration,
        user: user,
        provider: "custom",
        provider_account_id: "https://meet.jit.si/my-room",
        custom_meeting_url: "https://meet.jit.si/my-room"
      )

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")

      view
      |> element("button[phx-click='setup_provider'][phx-value-provider='custom']")
      |> render_click()

      html =
        view
        |> form("#custom-video-config-modal form", %{
          "integration" => %{
            "name" => "Duplicate Custom",
            "custom_meeting_url" => "https://meet.jit.si/my-room"
          }
        })
        |> render_submit()

      assert html =~ "A video integration with this configuration already exists"
    end

    test "refuses a custom video link with a malformed meeting ID placeholder", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")

      view
      |> element("button[phx-click='setup_provider'][phx-value-provider='custom']")
      |> render_click()

      view
      |> form("#custom-video-config-modal form", %{
        "integration" => %{
          "name" => "Per-booking Jitsi",
          "custom_meeting_url" => "https://meet.jit.si/{meeting_id}"
        }
      })
      |> render_submit()

      assert has_element?(
               view,
               "#custom-video-config-modal p.form-error",
               "Use double curly brackets: {{meeting_id}} not {meeting_id}"
             )

      assert Repo.all(VideoIntegrationSchema) == []
    end

    test "still adds a custom video link that is a static room", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")

      view
      |> element("button[phx-click='setup_provider'][phx-value-provider='custom']")
      |> render_click()

      view
      |> form("#custom-video-config-modal form", %{
        "integration" => %{
          "name" => "Team Room",
          "custom_meeting_url" => "https://meet.jit.si/my-room"
        }
      })
      |> render_submit()

      assert [%{custom_meeting_url: "https://meet.jit.si/my-room"}] =
               Repo.all(VideoIntegrationSchema)
    end

    test "connects kMeet without asking for a URL", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")

      view
      |> element("button[phx-click='setup_provider'][phx-value-provider='kmeet']")
      |> render_click()

      assert has_element?(view, "#kmeet-video-integration-form")

      refute has_element?(
               view,
               "#kmeet-video-integration-form input[name^='integration[']:not([name='integration[name]']):not([type='hidden'])"
             )

      assert has_element?(view, "#kmeet_host[readonly][value='https://kmeet.infomaniak.com']")

      view
      |> form("#kmeet-video-integration-form", integration: %{name: "My kMeet"})
      |> render_submit()

      assert render(view) =~ "Video integration added successfully"
      assert render(view) =~ "My kMeet"
      assert [%{provider: "kmeet", name: "My kMeet"}] = Video.list_integrations(user.id)
    end

    test "marks kMeet as connected and refuses a second kMeet with a clear message", %{
      conn: conn,
      user: user
    } do
      {:ok, _first} = Video.create_integration(user.id, :kmeet, %{name: "My kMeet"})

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")

      assert view
             |> element("button[phx-value-provider='kmeet']")
             |> render() =~ "Connected"

      view
      |> element("button[phx-click='setup_provider'][phx-value-provider='kmeet']")
      |> render_click()

      html =
        view
        |> form("#kmeet-video-integration-form", integration: %{name: "Second kMeet"})
        |> render_submit()

      assert html =~ "This provider is already connected"
      assert [%{name: "My kMeet"}] = Video.list_integrations(user.id)
    end

    test "renames a kMeet integration through the edit dialog", %{conn: conn, user: user} do
      {:ok, integration} = Video.create_integration(user.id, :kmeet, %{name: "My kMeet"})

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")

      view
      |> element(
        "button[phx-click='show'][phx-value-id='#{integration.id}'][phx-target='#edit-video-modal']"
      )
      |> render_click()

      assert has_element?(
               view,
               "#edit-video-integration-form #edit_kmeet_host[readonly][value='https://kmeet.infomaniak.com']"
             )

      view
      |> form("#edit-video-integration-form", integration: %{name: "Team kMeet"})
      |> render_submit()

      assert render(view) =~ "Integration updated successfully"
      assert Repo.get!(VideoIntegrationSchema, integration.id).name == "Team kMeet"
    end

    test "initiates google meet oauth", %{conn: conn} do
      expect(Tymeslot.GoogleOAuthHelperMock, :authorization_url, fn _uid, _uri, _scopes, _opts ->
        "https://accounts.google.com/o/oauth2/v2/auth"
      end)

      {:ok, view, _html} = live(conn, ~p"/dashboard/integrations?tab=video")

      view
      |> element("button[phx-click='setup_provider'][phx-value-provider='google_meet']")
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

    test "shows why a flagged video integration needs reconnecting", %{conn: conn, user: user} do
      insert(:video_integration,
        user: user,
        provider: "google_meet",
        is_active: true,
        needs_reauth: true,
        sync_error: "Stored credentials could not be decrypted."
      )

      {:ok, _view, html} = live(conn, ~p"/dashboard/integrations?tab=video")

      assert html =~ "Stored credentials could not be decrypted."
    end

    # sync_error also carries transient failures, which are not the owner's to
    # fix, so an unflagged row must keep the stored text to itself.
    test "keeps a stored sync error to itself while a video integration is not flagged", %{
      conn: conn,
      user: user
    } do
      insert(:video_integration,
        user: user,
        provider: "google_meet",
        is_active: true,
        needs_reauth: false,
        sync_error: "Timed out talking to the server."
      )

      {:ok, _view, html} = live(conn, ~p"/dashboard/integrations?tab=video")

      refute html =~ "Timed out talking to the server."
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
