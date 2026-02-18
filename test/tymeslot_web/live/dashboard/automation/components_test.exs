defmodule TymeslotWeb.Dashboard.Automation.ComponentsTest do
  @moduletag :utils
  use TymeslotWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  alias TymeslotWeb.Dashboard.Automation.Components

  describe "webhook_card" do
  @moduletag :utils
    test "renders active webhook correctly" do
      webhook = %{
        id: 1,
        name: "Test Webhook",
        url: "https://example.com/webhook",
        is_active: true,
        events: ["meeting.created", "meeting.cancelled"],
        last_triggered_at: ~U[2026-01-08 12:00:00Z],
        last_status: "success"
      }

      assigns = %{
        webhook: webhook,
        testing: false,
        target: "#webhook-1",
        on_edit: "edit",
        on_delete: "delete",
        on_toggle: "toggle",
        on_test: "test",
        on_view_deliveries: "logs"
      }

      html = render_component(&Components.webhook_card/1, assigns)
      assert html =~ "Test Webhook"
      assert html =~ "https://example.com/webhook"
      assert html =~ "meeting.created"
      assert html =~ "meeting.cancelled"
      assert html =~ "Last triggered"
      assert html =~ "success"
    end

    test "renders inactive webhook correctly" do
      webhook = %{
        id: 1,
        name: "Inactive Webhook",
        url: "https://example.com/webhook",
        is_active: false,
        events: [],
        last_triggered_at: nil,
        last_status: nil
      }

      assigns = %{
        webhook: webhook,
        testing: false,
        target: "#webhook-1",
        on_edit: "edit",
        on_delete: "delete",
        on_toggle: "toggle",
        on_test: "test",
        on_view_deliveries: "logs"
      }

      html = render_component(&Components.webhook_card/1, assigns)
      assert html =~ "Inactive Webhook"
      assert html =~ "Disabled"
      refute html =~ "Last triggered"
    end

    test "renders testing state" do
      webhook = %{
        id: 1,
        name: "Test Webhook",
        url: "https://example.com/webhook",
        is_active: true,
        events: [],
        last_triggered_at: nil,
        last_status: nil
      }

      assigns = %{
        webhook: webhook,
        testing: true,
        target: "#webhook-1",
        on_edit: "edit",
        on_delete: "delete",
        on_toggle: "toggle",
        on_test: "test",
        on_view_deliveries: "logs"
      }

      html = render_component(&Components.webhook_card/1, assigns)
      assert html =~ "animate-spin"
    end
  end

  describe "webhook_empty_state" do
    test "renders empty state" do
      assigns = %{on_create: "create"}
      html = render_component(&Components.webhook_empty_state/1, assigns)
      assert html =~ "No Webhooks Yet"
      assert html =~ "Create Your First Webhook"
    end
  end

  describe "webhook_documentation" do
    test "renders documentation" do
      assigns = %{}
      html = render_component(&Components.webhook_documentation/1, assigns)
      assert html =~ "Webhook Integration Guide"
      assert html =~ "meeting.created"
    end
  end
end
