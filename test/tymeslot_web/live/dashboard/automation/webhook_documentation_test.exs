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
  end
end
