defmodule TymeslotWeb.Themes.Rhythm.Shared.StatusBadgeTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :utils

  import Phoenix.LiveViewTest
  alias Floki
  alias TymeslotWeb.Themes.Rhythm.Shared.StatusBadge

  describe "status_badge/1 with success variant" do
    test "renders success badge with check icon by default" do
      assigns = %{variant: "success", icon: "check", transparent: false}
      html = render_component(&StatusBadge.status_badge/1, assigns)
      doc = Floki.parse_document!(html)

      assert Floki.find(doc, ".success-badge-inner--success") != []
      assert html =~ "M5 13l4 4L19 7"
    end

    test "applies transparent styling when transparent is true" do
      assigns = %{variant: "success", icon: "check", transparent: true}
      html = render_component(&StatusBadge.status_badge/1, assigns)
      doc = Floki.parse_document!(html)

      assert Floki.find(doc, ".success-badge--transparent") != []
    end

    test "does not apply transparent class when transparent is false" do
      assigns = %{variant: "success", icon: "check", transparent: false}
      html = render_component(&StatusBadge.status_badge/1, assigns)
      doc = Floki.parse_document!(html)

      assert Floki.find(doc, ".success-badge--transparent") == []
    end
  end

  describe "status_badge/1 with different variants" do
    test "renders info variant badge" do
      assigns = %{variant: "info", icon: "info", transparent: false}
      html = render_component(&StatusBadge.status_badge/1, assigns)
      doc = Floki.parse_document!(html)

      assert Floki.find(doc, ".success-badge-inner--info") != []
      assert html =~ "M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
    end

    test "renders danger variant badge" do
      assigns = %{variant: "danger", icon: "x", transparent: false}
      html = render_component(&StatusBadge.status_badge/1, assigns)
      doc = Floki.parse_document!(html)

      assert Floki.find(doc, ".success-badge-inner--danger") != []
      assert html =~ "M6 18L18 6M6 6l12 12"
    end

    test "renders warning variant badge" do
      assigns = %{variant: "warning", icon: "info", transparent: false}
      html = render_component(&StatusBadge.status_badge/1, assigns)
      doc = Floki.parse_document!(html)

      assert Floki.find(doc, ".success-badge-inner--warning") != []
    end
  end

  describe "status_badge/1 with different icons" do
    test "renders check icon" do
      assigns = %{variant: "success", icon: "check", transparent: false}
      html = render_component(&StatusBadge.status_badge/1, assigns)

      assert html =~ "M5 13l4 4L19 7"
      assert html =~ "stroke-width=\"3\""
    end

    test "renders x icon" do
      assigns = %{variant: "danger", icon: "x", transparent: false}
      html = render_component(&StatusBadge.status_badge/1, assigns)

      assert html =~ "M6 18L18 6M6 6l12 12"
    end

    test "renders info icon" do
      assigns = %{variant: "info", icon: "info", transparent: false}
      html = render_component(&StatusBadge.status_badge/1, assigns)

      assert html =~ "M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
    end

    test "renders refresh icon" do
      assigns = %{variant: "info", icon: "refresh", transparent: false}
      html = render_component(&StatusBadge.status_badge/1, assigns)

      assert html =~ "M4 4v5h.582m15.356 2A8.001 8.001 0 004.582 9m0 0H9m11 11v-5h-.581m0 0a8.003"
    end

    test "falls back to default icon for unknown icon names" do
      assigns = %{variant: "success", icon: "unknown", transparent: false}
      html = render_component(&StatusBadge.status_badge/1, assigns)

      # Default fallback icon
      assert html =~ "M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"
    end
  end

  describe "status_badge/1 default attributes" do
    test "uses success variant by default" do
      assigns = %{}
      html = render_component(&StatusBadge.status_badge/1, assigns)
      doc = Floki.parse_document!(html)

      assert Floki.find(doc, ".success-badge-inner--success") != []
    end

    test "uses check icon by default" do
      assigns = %{}
      html = render_component(&StatusBadge.status_badge/1, assigns)

      assert html =~ "M5 13l4 4L19 7"
    end

    test "uses non-transparent styling by default" do
      assigns = %{}
      html = render_component(&StatusBadge.status_badge/1, assigns)
      doc = Floki.parse_document!(html)

      assert Floki.find(doc, ".success-badge--transparent") == []
    end
  end

  describe "status_badge/1 visual structure" do
    test "renders with correct container classes" do
      assigns = %{variant: "success", icon: "check", transparent: false}
      html = render_component(&StatusBadge.status_badge/1, assigns)
      doc = Floki.parse_document!(html)

      assert Floki.find(doc, ".success-badge") != []
      assert Floki.find(doc, ".success-icon") != []
    end

    test "SVG has proper viewBox and stroke attributes" do
      assigns = %{variant: "info", icon: "info", transparent: false}
      html = render_component(&StatusBadge.status_badge/1, assigns)

      assert html =~ ~s(viewBox="0 0 24 24")
      assert html =~ ~s(fill="none")
      assert html =~ ~s(stroke="currentColor")
    end
  end

  describe "status_badge/1 variant and icon combinations" do
    test "success with check icon displays correctly" do
      assigns = %{variant: "success", icon: "check", transparent: false}
      html = render_component(&StatusBadge.status_badge/1, assigns)

      assert html =~ "success-badge-inner--success"
      assert html =~ "M5 13l4 4L19 7"
    end

    test "danger with x icon displays correctly" do
      assigns = %{variant: "danger", icon: "x", transparent: false}
      html = render_component(&StatusBadge.status_badge/1, assigns)

      assert html =~ "success-badge-inner--danger"
      assert html =~ "M6 18L18 6M6 6l12 12"
    end

    test "warning with refresh icon displays correctly" do
      assigns = %{variant: "warning", icon: "refresh", transparent: false}
      html = render_component(&StatusBadge.status_badge/1, assigns)

      assert html =~ "success-badge-inner--warning"
      assert html =~ "M4 4v5h.582m15.356 2A8.001"
    end

    test "info with info icon displays correctly" do
      assigns = %{variant: "info", icon: "info", transparent: false}
      html = render_component(&StatusBadge.status_badge/1, assigns)

      assert html =~ "success-badge-inner--info"
      assert html =~ "M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
    end
  end
end
