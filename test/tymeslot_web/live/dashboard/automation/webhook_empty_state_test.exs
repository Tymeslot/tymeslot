defmodule TymeslotWeb.Dashboard.Automation.WebhookEmptyStateTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :utils

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Dashboard.Automation.WebhookEmptyState

  describe "webhook_empty_state/1" do
    test "renders empty state" do
      assigns = %{on_create: "create"}
      html = render_component(&WebhookEmptyState.webhook_empty_state/1, assigns)
      assert html =~ "No Webhooks Yet"
      assert html =~ "Create Your First Webhook"
    end
  end
end
