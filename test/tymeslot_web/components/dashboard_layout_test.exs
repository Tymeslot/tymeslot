defmodule TymeslotWeb.Components.DashboardLayoutTest do
  use TymeslotWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Phoenix.Component
  import Tymeslot.Factory
  alias Floki
  alias TymeslotWeb.Components.DashboardLayout

  test "renders dashboard layout with sidebar and top navigation" do
    assigns = %{}
    user = build(:user)
    profile = build(:profile, user: user, username: "testuser", full_name: "Test User")

    component_assigns = %{
      current_user: user,
      profile: profile,
      current_action: :overview,
      integration_status: %{has_calendar: true},
      inner_block: [%{__slot__: :inner_block, inner_block: fn _assigns, _changed -> ~H"Main Content" end}]
    }

    html = render_component(&DashboardLayout.dashboard_layout/1, component_assigns)
    doc = Floki.parse_document!(html)

    assert html =~ "Tymeslot"
    assert html =~ "Test User"
    assert html =~ "Main Content"

    assert Floki.find(doc, "div#dashboard-root[phx-hook='ClipboardCopy']") != []
    assert Floki.find(doc, "aside#dashboard-sidebar") != []
    assert Floki.find(doc, "nav.brand-nav") != []
  end

  test "top_navigation renders correctly" do
    user = build(:user)
    profile = build(:profile, user: user, username: "testuser", full_name: "Test User")

    assigns = %{
      current_user: user,
      profile: profile
    }

    html = render_component(&DashboardLayout.top_navigation/1, assigns)
    doc = Floki.parse_document!(html)

    assert html =~ "Tymeslot"
    assert html =~ "Test User"

    assert Floki.find(doc, "button[aria-label='Toggle sidebar']") != []
  end
end
