defmodule TymeslotWeb.Dashboard.Automation.WebhookDocumentationTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :utils

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Dashboard.Automation.WebhookDocumentation

  describe "webhook_documentation/1" do
    test "renders documentation" do
      assigns = %{}
      html = render_component(&WebhookDocumentation.webhook_documentation/1, assigns)
      assert html =~ "Webhook Integration Guide"
      assert html =~ "meeting.created"
    end

    test "documents the delivery id header that lets receivers discard duplicates" do
      html = render_component(&WebhookDocumentation.webhook_documentation/1, %{})

      assert html =~ "X-Tymeslot-Delivery-Id"
      assert html =~ "the same on every retry of one delivery"
    end
  end
end
