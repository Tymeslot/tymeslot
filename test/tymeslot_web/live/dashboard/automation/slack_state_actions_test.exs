defmodule TymeslotWeb.Dashboard.Automation.SlackStateActionsTest do
  @moduledoc """
  Covers the per-card state actions — Test, Disconnect, Reconnect, Re-enable —
  and the OAuth channel-picker save flow. The existing
  `SlackEventHandlersTest` covers form lifecycle, toggle, delete, and OAuth
  deep-link entry; this suite picks up the user actions on already-created
  integrations.
  """

  use TymeslotWeb.ConnCase, async: false

  @moduletag :slack
  @moduletag :live
  @moduletag :integration

  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.TestFixtures
  import Tymeslot.Factory

  alias Tymeslot.Auth.UserQueries
  alias Tymeslot.ConfigTestHelpers
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Slack

  setup :verify_on_exit!

  setup %{conn: conn} do
    user = create_user_fixture()
    {:ok, user} = UserQueries.mark_onboarding_complete(user)

    ConfigTestHelpers.setup_config(:tymeslot,
      slack_notifications_allowed: true,
      slack_oauth_available: true,
      slack_client_id: "test-client-id",
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      dashboard_additional_hooks: [],
      feature_placeholder_components: %{},
      http_client_module: Tymeslot.HTTPClientMock
    )

    stub(Tymeslot.HTTPClientMock, :get, fn _url, _headers, _opts ->
      {:error, %Mint.TransportError{reason: :timeout}}
    end)

    conn = log_in_user(conn, user)
    {:ok, conn: conn, user: user}
  end

  defp open_slack_tab(view) do
    view |> element("button", "Slack") |> render_click()
    render(view)
  end

  defp webhook_integration(user, attrs \\ %{}) do
    defaults = %{
      user: user,
      app_mode: "webhook_url",
      webhook_url_encrypted:
        Encryption.encrypt("https://hooks.slack.com/services/TABC/BABC/secrettoken"),
      bot_token_encrypted: nil,
      team_id: nil,
      channel_id: nil,
      channel_name: nil,
      is_active: true
    }

    insert(:slack_integration, Map.merge(defaults, attrs))
  end

  defp oauth_integration(user, attrs \\ %{}) do
    defaults = %{
      user: user,
      app_mode: "oauth",
      bot_token_encrypted: Encryption.encrypt("xoxb-test-token"),
      channel_id: "C123",
      channel_name: "#bookings",
      is_active: true
    }

    insert(:slack_integration, Map.merge(defaults, attrs))
  end

  # ---------------------------------------------------------------------------
  # Test connection
  # ---------------------------------------------------------------------------

  describe "Test connection (webhook URL)" do
    test "POSTs to the webhook URL and shows a success flash", %{conn: conn, user: user} do
      _integration = webhook_integration(user)

      expect(Tymeslot.HTTPClientMock, :post, fn url, _body, _headers, _opts ->
        assert url == "https://hooks.slack.com/services/TABC/BABC/secrettoken"
        {:ok, %{status: 200, body: "ok"}}
      end)

      {:ok, view, _html} = live(conn, "/dashboard/automation")
      open_slack_tab(view)

      view |> element("button", "Test") |> render_click()

      assert render(view) =~ "Test message sent"
    end

    test "does not flash success when delivery fails", %{conn: conn, user: user} do
      _integration = webhook_integration(user)

      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %{status: 403, body: "invalid_token"}}
      end)

      {:ok, view, _html} = live(conn, "/dashboard/automation")
      open_slack_tab(view)

      view |> element("button", "Test") |> render_click()

      refute render(view) =~ "Test message sent"
    end
  end

  # ---------------------------------------------------------------------------
  # Disconnect
  # ---------------------------------------------------------------------------

  describe "Disconnect" do
    test "OAuth integration: clears channel and demotes back to pending", %{
      conn: conn,
      user: user
    } do
      integration = oauth_integration(user)

      {:ok, view, _html} = live(conn, "/dashboard/automation")
      open_slack_tab(view)

      view
      |> element("button[title='Disconnect Slack']")
      |> render_click()

      assert render(view) =~ "Slack channel disconnected"

      {:ok, refreshed} = Slack.get_integration(integration.id, user.id)
      assert refreshed.channel_id == nil
      assert refreshed.channel_name == nil
      # Bot token and workspace metadata are preserved so the user can pick a
      # new channel without redoing OAuth.
      assert refreshed.bot_token_encrypted == integration.bot_token_encrypted
    end

    test "webhook URL integrations cannot be disconnected via the OAuth path", %{
      conn: conn,
      user: user
    } do
      # Webhook URL cards never render the Disconnect button (only OAuth + channel_id
      # combination shows it). Confirm by absence.
      _integration = webhook_integration(user)

      {:ok, view, _html} = live(conn, "/dashboard/automation")
      html = open_slack_tab(view)

      refute html =~ "title=\"Disconnect Slack\""
    end
  end

  # ---------------------------------------------------------------------------
  # Reconnect
  # ---------------------------------------------------------------------------

  describe "Reconnect (pending_oauth)" do
    test "shows Reconnect button on pending OAuth integrations", %{conn: conn, user: user} do
      _integration = oauth_integration(user, %{channel_id: nil, channel_name: nil})

      {:ok, view, _html} = live(conn, "/dashboard/automation")
      html = open_slack_tab(view)

      assert html =~ "Reconnect"
    end

    test "Reconnect redirects to the OAuth start endpoint", %{conn: conn, user: user} do
      _integration = oauth_integration(user, %{channel_id: nil, channel_name: nil})

      {:ok, view, _html} = live(conn, "/dashboard/automation")
      open_slack_tab(view)

      assert {:error, {:redirect, %{to: "/api/slack/oauth/start"}}} =
               view |> element("button", "Reconnect") |> render_click()
    end

    test "does not show Reconnect on active OAuth integrations", %{conn: conn, user: user} do
      _integration = oauth_integration(user)

      {:ok, view, _html} = live(conn, "/dashboard/automation")
      html = open_slack_tab(view)

      refute html =~ "Reconnect"
    end

    test "does not show Reconnect on webhook URL integrations", %{conn: conn, user: user} do
      _integration = webhook_integration(user)

      {:ok, view, _html} = live(conn, "/dashboard/automation")
      html = open_slack_tab(view)

      refute html =~ "Reconnect"
    end

    test "hides Reconnect on pending integrations when OAuth is unavailable",
         %{conn: conn, user: user} do
      # Without OAuth available, restarting the install flow would 500, so the
      # button must not be offered.
      ConfigTestHelpers.setup_config(:tymeslot,
        slack_oauth_available: false,
        slack_client_id: nil
      )

      _integration = oauth_integration(user, %{channel_id: nil, channel_name: nil})

      {:ok, view, _html} = live(conn, "/dashboard/automation")
      html = open_slack_tab(view)

      refute html =~ "Reconnect"
    end
  end

  # ---------------------------------------------------------------------------
  # Re-enable
  # ---------------------------------------------------------------------------

  describe "Re-enable" do
    test "transitions an auto-disabled integration back to active", %{conn: conn, user: user} do
      integration =
        webhook_integration(user, %{
          is_active: true,
          disabled_at: DateTime.utc_now(:second)
        })

      {:ok, view, _html} = live(conn, "/dashboard/automation")
      open_slack_tab(view)

      view |> element("button", "Re-enable") |> render_click()

      assert render(view) =~ "Slack integration re-enabled"

      {:ok, refreshed} = Slack.get_integration(integration.id, user.id)
      assert refreshed.disabled_at == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Edit existing integration
  # ---------------------------------------------------------------------------

  describe "Edit" do
    test "opens the edit form pre-filled and submits a name change", %{
      conn: conn,
      user: user
    } do
      integration = webhook_integration(user, %{name: "Original Name"})

      {:ok, view, _html} = live(conn, "/dashboard/automation")
      open_slack_tab(view)

      view |> element("button[title='Edit']") |> render_click()

      html = render(view)
      assert html =~ "Original Name"

      view
      |> form("#slack-form", %{
        "slack" => %{
          "name" => "Renamed Channel",
          "webhook_url" => "https://hooks.slack.com/services/TABC/BABC/secrettoken",
          "webhook_channel_hint" => "#bookings",
          "events" => ["meeting.created"]
        }
      })
      |> render_submit()

      assert render(view) =~ "Slack integration updated"

      {:ok, refreshed} = Slack.get_integration(integration.id, user.id)
      assert refreshed.name == "Renamed Channel"
    end
  end

  # ---------------------------------------------------------------------------
  # Save channel from OAuth picker
  # ---------------------------------------------------------------------------

  describe "Save channel from OAuth picker" do
    test "promotes a pending OAuth integration to active by setting the channel", %{
      conn: conn,
      user: user
    } do
      pending = oauth_integration(user, %{channel_id: nil, channel_name: nil})

      # Same channel list for the initial load and the post-validation render.
      stub(Tymeslot.HTTPClientMock, :get, fn _url, _headers, _opts ->
        body =
          Jason.encode!(%{
            "ok" => true,
            "channels" => [
              %{"id" => "C999", "name" => "team-bookings", "is_private" => false}
            ],
            "response_metadata" => %{"next_cursor" => ""}
          })

        {:ok, %{status: 200, body: body}}
      end)

      {:ok, view, _html} = live(conn, "/dashboard/automation?slack_pending=#{pending.id}")
      _initial_html = render_async(view)

      # First trigger validation so the form_values picks up channel_id, which the
      # hidden channel_name input depends on. Then submit.
      view
      |> form("#slack-form", %{
        "slack" => %{
          "channel_id" => "C999",
          "events" => ["meeting.created"]
        }
      })
      |> render_change()

      view
      |> form("#slack-form", %{
        "slack" => %{
          "channel_id" => "C999",
          "events" => ["meeting.created"]
        }
      })
      |> render_submit()

      assert render(view) =~ "Slack channel saved"

      {:ok, refreshed} = Slack.get_integration(pending.id, user.id)
      assert refreshed.channel_id == "C999"
      assert refreshed.channel_name == "team-bookings"
    end
  end
end
