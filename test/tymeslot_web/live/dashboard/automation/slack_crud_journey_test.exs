defmodule TymeslotWeb.Dashboard.Automation.SlackCrudJourneyTest do
  @moduledoc """
  The organiser's Slack configuration journey: add an integration, edit it,
  switch it off, disconnect it.

  Webhooks already have this test — `AutomationIntegrationTest` walks create,
  edit, delete, validation errors, token regeneration and delivery stats.
  Slack had nothing equivalent. `SlackCompositionTest` covers the *surface*
  around the form (tab visibility, empty-state CTAs, the OAuth deep link, the
  feature gate, and that a stored webhook URL is never echoed back into the
  edit form) but never submits it, so the handlers behind the form were only
  reached by the parts of the page that render before anyone types anything.

  The asymmetry showed up in coverage: `Slack.CrudHandlers` and
  `Slack.FormHandlers` sat at roughly half and a quarter of their lines while
  the `Tymeslot.Slack` context they call sat above 85%. The domain was proven;
  the path a user takes to reach it was not.

  Deliberately not covered here:

    * OAuth install (`slack_save_channel` after a workspace connect) — needs a
      real Slack OAuth round trip and belongs with the `:oauth_integration`
      tagged tests, which are excluded by default.
    * Message formatting and delivery — `Tymeslot.Slack.MessageBuilder` and
      `Slack.Dispatcher` own that, and both are covered.
  """

  use TymeslotWeb.ConnCase, async: false

  @moduletag :slack
  @moduletag :automation
  @moduletag :live
  @moduletag :integration

  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory
  import Tymeslot.TestFixtures

  alias Tymeslot.Auth.UserQueries
  alias Tymeslot.ConfigTestHelpers
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Slack

  # Shaped like a real webhook URL but with a deliberately short token
  # segment, matching the other Slack tests. A full-length token trips the
  # gitleaks `slack-webhook-url` rule, and that rule stays active everywhere
  # by design — only entropy-based generic matches are ever allowlisted.
  @webhook_url "https://hooks.slack.com/services/TABC123/BABC123/sometoken123"

  setup %{conn: conn} do
    user = create_user_fixture()
    {:ok, user} = UserQueries.mark_onboarding_complete(user)

    ConfigTestHelpers.setup_config(:tymeslot,
      slack_notifications_allowed: true,
      slack_oauth_available: true,
      slack_client_id: "test-client-id",
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      dashboard_additional_hooks: [],
      feature_placeholder_components: %{}
    )

    {:ok, conn: log_in_user(conn, user), user: user}
  end

  # The edit control pushes a JS command, so its integration id is encoded in
  # the serialised `phx-click` payload rather than a `phx-value-id` attribute.
  defp edit_button(integration) do
    ~s([phx-click*='slack_show_edit_form'][phx-click*='"id":#{integration.id}'])
  end

  defp open_slack_tab(conn) do
    {:ok, view, _html} = live(conn, "/dashboard/automation")
    view |> element("button", "Slack") |> render_click()
    view
  end

  defp open_webhook_form(conn) do
    view = open_slack_tab(conn)
    view |> element("button", "Add via webhook URL") |> render_click()
    view
  end

  describe "adding a Slack integration via webhook URL" do
    test "a valid submission persists the integration and shows it in the list", %{
      conn: conn,
      user: user
    } do
      view = open_webhook_form(conn)

      view
      |> form("form[phx-submit='slack_save_webhook']", %{
        "slack" => %{
          "name" => "Team Bookings",
          "webhook_url" => @webhook_url,
          "webhook_channel_hint" => "#bookings",
          "events" => ["meeting.created"]
        }
      })
      |> render_submit()

      assert [integration] = Slack.list_integrations(user.id)
      assert integration.name == "Team Bookings"
      assert integration.events == ["meeting.created"]
      assert integration.is_active

      assert render(view) =~ "Team Bookings"
    end

    test "the stored webhook URL is never rendered back to the page", %{conn: conn} do
      view = open_webhook_form(conn)

      view
      |> form("form[phx-submit='slack_save_webhook']", %{
        "slack" => %{
          "name" => "Secret Hook",
          "webhook_url" => @webhook_url,
          "webhook_channel_hint" => "#bookings",
          "events" => ["meeting.created"]
        }
      })
      |> render_submit()

      # The credential is encrypted at rest; a round trip through the list
      # must not put it back on the wire.
      refute render(view) =~ @webhook_url
    end

    test "a malformed webhook URL is rejected and nothing is persisted", %{
      conn: conn,
      user: user
    } do
      view = open_webhook_form(conn)

      view
      |> form("form[phx-submit='slack_save_webhook']", %{
        "slack" => %{
          "name" => "Bad Hook",
          "webhook_url" => "not-a-url",
          "webhook_channel_hint" => "#bookings",
          "events" => ["meeting.created"]
        }
      })
      |> render_submit()

      assert Slack.list_integrations(user.id) == []
      refute render(view) =~ "Bad Hook"
    end

    test "a submission with no events selected is rejected", %{conn: conn, user: user} do
      view = open_webhook_form(conn)

      view
      |> form("form[phx-submit='slack_save_webhook']", %{
        "slack" => %{
          "name" => "No Events",
          "webhook_url" => @webhook_url,
          "webhook_channel_hint" => "#bookings",
          "events" => []
        }
      })
      |> render_submit()

      assert Slack.list_integrations(user.id) == [],
             "an integration subscribed to nothing would never fire; it must not save"
    end
  end

  describe "editing an existing Slack integration" do
    setup %{user: user} do
      integration =
        insert(:slack_integration,
          user: user,
          name: "Original Name",
          app_mode: "webhook_url",
          webhook_url_encrypted: Encryption.encrypt(@webhook_url),
          events: ["meeting.created"],
          is_active: true
        )

      %{integration: integration}
    end

    test "the edit form opens prefilled with the current name", %{
      conn: conn,
      integration: integration
    } do
      view = open_slack_tab(conn)

      view
      |> element(edit_button(integration))
      |> render_click()

      assert render(view) =~ "Original Name"
    end

    test "renaming and re-subscribing persists both changes", %{
      conn: conn,
      user: user,
      integration: integration
    } do
      view = open_slack_tab(conn)

      view
      |> element(edit_button(integration))
      |> render_click()

      view
      |> form("form[phx-submit='slack_update']", %{
        "slack" => %{
          "name" => "Renamed Workspace",
          "webhook_url" => "",
          "webhook_channel_hint" => "#general",
          "events" => ["meeting.cancelled", "meeting.rescheduled"]
        }
      })
      |> render_submit()

      assert [updated] = Slack.list_integrations(user.id)
      assert updated.name == "Renamed Workspace"
      assert Enum.sort(updated.events) == ["meeting.cancelled", "meeting.rescheduled"]
    end

    test "leaving the webhook URL blank keeps the stored credential", %{
      conn: conn,
      user: user,
      integration: integration
    } do
      {:ok, original_secret} = Slack.get_integration(integration.id, user.id)

      view = open_slack_tab(conn)

      view
      |> element(edit_button(integration))
      |> render_click()

      view
      |> form("form[phx-submit='slack_update']", %{
        "slack" => %{
          "name" => "Kept Credential",
          "webhook_url" => "",
          "webhook_channel_hint" => "#general",
          "events" => ["meeting.created"]
        }
      })
      |> render_submit()

      {:ok, reloaded} = Slack.get_integration(integration.id, user.id)

      assert reloaded.name == "Kept Credential"

      refute is_nil(original_secret.webhook_url_encrypted),
             "setup must store a credential, or the comparison below is nil == nil"

      assert reloaded.webhook_url_encrypted == original_secret.webhook_url_encrypted,
             "an edit that leaves the URL field blank must not blank the stored credential"
    end
  end

  describe "switching an integration off" do
    setup %{user: user} do
      integration =
        insert(:slack_integration,
          user: user,
          name: "Toggle Me",
          app_mode: "webhook_url",
          webhook_url_encrypted: Encryption.encrypt(@webhook_url),
          events: ["meeting.created"],
          is_active: true
        )

      %{integration: integration}
    end

    test "toggling active off stops it firing but keeps the row", %{
      conn: conn,
      user: user,
      integration: integration
    } do
      view = open_slack_tab(conn)

      view
      |> element("[phx-click='slack_toggle_active'][phx-value-id='#{integration.id}']")
      |> render_click()

      {:ok, reloaded} = Slack.get_integration(integration.id, user.id)

      refute reloaded.is_active
      assert reloaded.name == "Toggle Me", "toggling off must not delete the integration"
    end
  end
end
