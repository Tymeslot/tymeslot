defmodule TymeslotWeb.Dashboard.Automation.WebhookCardTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :utils

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Dashboard.Automation.WebhookCard

  describe "webhook_card/1" do
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
        time_format: "12h",
        target: "#webhook-1",
        on_edit: "edit",
        on_delete: "delete",
        on_toggle: "toggle",
        on_test: "test",
        on_view_deliveries: "logs"
      }

      html = render_component(&WebhookCard.webhook_card/1, assigns)
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

      html = render_component(&WebhookCard.webhook_card/1, assigns)
      assert html =~ "Inactive Webhook"
      assert html =~ "Disabled"
      refute html =~ "Last triggered"
    end

    test "renders testing state with the button disabled and showing 'Testing' label" do
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

      html = render_component(&WebhookCard.webhook_card/1, assigns)
      # The button text changes to "Testing" and it becomes disabled while a test is in progress
      assert html =~ "Testing"
      assert html =~ ~r/<button[^>]+disabled/
    end
  end
end
