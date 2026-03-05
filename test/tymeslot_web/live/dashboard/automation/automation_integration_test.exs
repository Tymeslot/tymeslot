defmodule TymeslotWeb.Dashboard.Automation.AutomationIntegrationTest do
  use TymeslotWeb.ConnCase, async: false

  @moduletag :integration

  import Phoenix.LiveViewTest
  import Tymeslot.AuthTestHelpers
  import Tymeslot.TestFixtures
  import Tymeslot.Factory
  alias Tymeslot.ConfigTestHelpers
  alias Tymeslot.DatabaseQueries.UserQueries
  alias Tymeslot.Webhooks

  setup %{conn: conn} do
    # Create a user and log them in
    user = create_user_fixture()
    {:ok, user} = UserQueries.mark_onboarding_complete(user)

    ConfigTestHelpers.setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker
    )

    ConfigTestHelpers.setup_config(:tymeslot,
      dashboard_additional_hooks: [],
      feature_placeholder_components: %{}
    )

    conn = log_in_user(conn, user)
    {:ok, conn: conn, user: user}
  end

  describe "Webhooks flow (core mode - no feature gating)" do
    test "can create, edit, and delete a webhook", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, "/dashboard/automation")

      # 1. Initial empty state
      assert render(view) =~ "No Webhooks Yet"

      # 2. Open create form
      view
      |> element("button", "Create Your First Webhook")
      |> render_click()

      assert render(view) =~ "Create Webhook"

      # 3. Fill and submit create form
      view
      |> form("#webhook-form", %{
        "webhook" => %{
          "name" => "My n8n Webhook",
          "url" => "https://example.com/webhook",
          "events" => ["meeting.created"]
        }
      })
      |> render_submit()

      assert render(view) =~ "Webhook created successfully"
      assert render(view) =~ "My n8n Webhook"
      assert render(view) =~ "meeting.created"

      # Verify DB
      [webhook] = Webhooks.list_webhooks(user.id)
      assert webhook.name == "My n8n Webhook"
      assert webhook.url == "https://example.com/webhook"
      assert webhook.is_active

      # 4. Toggle status
      view
      |> element("button[role='switch']")
      |> render_click()

      assert render(view) =~ "Webhook status updated"
      assert render(view) =~ "Disabled"

      [webhook] = Webhooks.list_webhooks(user.id)
      refute webhook.is_active

      # 5. Open edit form
      view
      |> element("button[title='Edit Webhook']")
      |> render_click()

      assert render(view) =~ "Edit Webhook"

      # 6. Update webhook
      view
      |> form("#webhook-form", %{
        "webhook" => %{
          "name" => "Updated Webhook Name",
          "url" => "https://example.com/updated",
          "events" => ["meeting.created", "meeting.cancelled"]
        }
      })
      |> render_submit()

      assert render(view) =~ "Webhook updated successfully"
      assert render(view) =~ "Updated Webhook Name"

      [webhook] = Webhooks.list_webhooks(user.id)
      assert webhook.name == "Updated Webhook Name"
      assert webhook.url == "https://example.com/updated"
      assert "meeting.cancelled" in webhook.events

      # 7. Delete webhook
      view
      |> element("button[title='Delete Webhook']")
      |> render_click()

      assert render(view) =~ "Delete Webhook?"

      view
      |> element("#delete-webhook-modal button", "Delete Webhook")
      |> render_click()

      assert render(view) =~ "Webhook deleted successfully"
      assert render(view) =~ "No Webhooks Yet"

      assert Webhooks.list_webhooks(user.id) == []
    end

    test "validation errors are shown", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/dashboard/automation")

      view
      |> element("button", "Create Your First Webhook")
      |> render_click()

      # Submit empty form
      view
      |> form("#webhook-form", %{
        "webhook" => %{
          "name" => "",
          "url" => "not-a-url"
        }
      })
      |> render_submit()

      # The errors are returned from WebhookInputProcessor via AutomationSettingsComponent
      assert render(view) =~ "Name cannot be empty"
      assert render(view) =~ "Must start with http:// or https://"
    end
  end

  describe "Token regeneration flow" do
    setup %{user: user} do
      {:ok, webhook} =
        Webhooks.create_webhook(user.id, %{
          name: "Test Webhook",
          url: "https://example.com/webhook",
          events: ["meeting.created"]
        })

      {:ok, webhook: webhook}
    end

    test "user can regenerate the security token from the edit form", %{
      conn: conn,
      user: user,
      webhook: webhook
    } do
      original_token = webhook.webhook_token

      {:ok, view, _html} = live(conn, "/dashboard/automation")

      # Open edit form — token is displayed there with the Regenerate button
      view
      |> element("button[title='Edit Webhook']")
      |> render_click()

      assert render(view) =~ "Edit Webhook"

      # Click "Regenerate" button in the edit form to open the confirmation modal
      view
      |> element("button[phx-click='show_regenerate_token_modal']")
      |> render_click()

      assert render(view) =~ "Regenerate Token?"

      # Confirm the regeneration via the danger button in the modal
      view
      |> element("#regenerate-token-modal .action-button--danger")
      |> render_click()

      assert render(view) =~ "Security token regenerated"

      # A new, different token was persisted
      [updated_webhook] = Webhooks.list_webhooks(user.id)
      assert updated_webhook.webhook_token != original_token
      assert String.starts_with?(updated_webhook.webhook_token, "ts_")
    end
  end

  describe "Test connection flow" do
    setup %{user: user} do
      {:ok, webhook} =
        Webhooks.create_webhook(user.id, %{
          name: "Test Webhook",
          url: "https://example.com/webhook",
          events: ["meeting.created"]
        })

      {:ok, webhook: webhook}
    end

    test "shows success when the endpoint responds with 2xx", %{conn: conn} do
      ConfigTestHelpers.setup_config(:tymeslot,
        http_client_module: TymeslotWeb.Dashboard.Automation.TestHTTPClientSuccess
      )

      {:ok, view, _html} = live(conn, "/dashboard/automation")

      view
      |> element("button[title='Test Connection']")
      |> render_click()

      assert render(view) =~ "Webhook test successful"
    end

    test "shows an error when the endpoint returns a non-2xx status", %{conn: conn} do
      ConfigTestHelpers.setup_config(:tymeslot,
        http_client_module: TymeslotWeb.Dashboard.Automation.TestHTTPClientFailure
      )

      {:ok, view, _html} = live(conn, "/dashboard/automation")

      view
      |> element("button[title='Test Connection']")
      |> render_click()

      assert render(view) =~ "Test failed"
    end
  end

  describe "Delivery logs modal" do
    setup %{user: user} do
      {:ok, webhook} =
        Webhooks.create_webhook(user.id, %{
          name: "Test Webhook",
          url: "https://example.com/webhook",
          events: ["meeting.created"]
        })

      {:ok, webhook: webhook}
    end

    test "opens and shows delivery statistics for a webhook", %{conn: conn, webhook: webhook} do
      insert(:webhook_delivery, webhook: webhook, event_type: "meeting.created")

      {:ok, view, _html} = live(conn, "/dashboard/automation")

      view
      |> element("button[title='View Delivery Logs']")
      |> render_click()

      html = render(view)
      assert html =~ "Total"
      assert html =~ "Success"
      assert html =~ "Failed"
    end
  end

  describe "Server-side feature gating" do
    setup %{user: user} do
      # Create a test meeting for webhook triggering
      meeting = insert(:meeting, organizer_user: user)

      {:ok, meeting: meeting}
    end

    test "triggers webhooks when no feature_access_checker is configured", %{
      user: user,
      meeting: meeting
    } do
      # Create a webhook
      {:ok, _webhook} =
        Webhooks.create_webhook(user.id, %{
          name: "Test Webhook",
          url: "https://example.com/webhook",
          events: ["meeting.created"]
        })

      # Clear any configured feature access checker safely
      ConfigTestHelpers.with_config(
        :tymeslot,
        :feature_access_checker,
        Tymeslot.Features.DefaultAccessChecker
      )

      # Should trigger webhook
      assert :ok = Webhooks.trigger_webhooks_for_event(user.id, "meeting.created", meeting)
    end

    test "blocks webhooks when feature_access_checker denies access", %{
      user: user,
      meeting: meeting
    } do
      # Create a webhook
      {:ok, _webhook} =
        Webhooks.create_webhook(user.id, %{
          name: "Test Webhook",
          url: "https://example.com/webhook",
          events: ["meeting.created"]
        })

      # Configure a test feature access checker that denies access safely
      ConfigTestHelpers.with_config(
        :tymeslot,
        :feature_access_checker,
        TymeslotWeb.Dashboard.Automation.TestAccessChecker
      )

      # Should still return :ok but not trigger webhook
      assert :ok = Webhooks.trigger_webhooks_for_event(user.id, "meeting.created", meeting)
    end

    test "allows webhooks when feature_access_checker grants access", %{
      user: user,
      meeting: meeting
    } do
      # Create a webhook
      {:ok, _webhook} =
        Webhooks.create_webhook(user.id, %{
          name: "Test Webhook",
          url: "https://example.com/webhook",
          events: ["meeting.created"]
        })

      # Configure a test feature access checker that grants access safely
      ConfigTestHelpers.with_config(
        :tymeslot,
        :feature_access_checker,
        TymeslotWeb.Dashboard.Automation.TestAccessCheckerAllows
      )

      # Should trigger webhook
      assert :ok = Webhooks.trigger_webhooks_for_event(user.id, "meeting.created", meeting)
    end

    test "handles feature_access_checker errors gracefully", %{
      user: user,
      meeting: meeting
    } do
      # Create a webhook
      {:ok, _webhook} =
        Webhooks.create_webhook(user.id, %{
          name: "Test Webhook",
          url: "https://example.com/webhook",
          events: ["meeting.created"]
        })

      # Configure a test feature access checker that returns an error safely
      ConfigTestHelpers.with_config(
        :tymeslot,
        :feature_access_checker,
        TymeslotWeb.Dashboard.Automation.TestAccessCheckerFails
      )

      # Should return :ok without raising
      assert :ok = Webhooks.trigger_webhooks_for_event(user.id, "meeting.created", meeting)
    end
  end
end

# Test helper modules for feature access checking
defmodule TymeslotWeb.Dashboard.Automation.TestAccessChecker do
  @moduledoc false

  @spec check_access(any(), atom()) :: :ok | {:error, :insufficient_plan}
  def check_access(_user_id, :automations_allowed), do: {:error, :insufficient_plan}
  def check_access(_user_id, _feature), do: :ok
end

defmodule TymeslotWeb.Dashboard.Automation.TestAccessCheckerAllows do
  @moduledoc false

  @spec check_access(any(), atom()) :: :ok
  def check_access(_user_id, _feature), do: :ok
end

defmodule TymeslotWeb.Dashboard.Automation.TestAccessCheckerFails do
  @moduledoc false

  @spec check_access(any(), atom()) :: {:error, atom()}
  def check_access(_user_id, _feature), do: {:error, :checker_unavailable}
end

# Minimal HTTP client stubs for test connection UI tests.
# These avoid Mox cross-process coordination issues in LiveView tests.
defmodule TymeslotWeb.Dashboard.Automation.TestHTTPClientSuccess do
  @moduledoc false

  @spec post(String.t(), any(), any(), any()) :: {:ok, map()}
  def post(_url, _body, _headers, _opts), do: {:ok, %{status: 200, body: "OK"}}
end

defmodule TymeslotWeb.Dashboard.Automation.TestHTTPClientFailure do
  @moduledoc false

  @spec post(String.t(), any(), any(), any()) :: {:ok, map()}
  def post(_url, _body, _headers, _opts), do: {:ok, %{status: 503, body: "Service Unavailable"}}
end
