defmodule TymeslotWeb.Components.UITest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :utils

  import Phoenix.LiveViewTest
  import Phoenix.Component
  alias TymeslotWeb.Components.UI.CloseButton
  alias TymeslotWeb.Components.UI.StatusSwitch
  alias TymeslotWeb.Components.UI.Toggle
  alias TymeslotWeb.Components.UI.ToggleGroup
  alias TymeslotWeb.Components.UIComponents

  describe "CloseButton" do
    test "renders correctly with default attributes" do
      assigns = %{phx_click: "close"}
      html = render_component(&CloseButton.close_button/1, assigns)

      assert html =~ "Close"
      assert html =~ "phx-click=\"close\""
      assert html =~ "title=\"Close\""
    end

    test "renders without label when show_label is false" do
      assigns = %{phx_click: "close", show_label: false}
      html = render_component(&CloseButton.close_button/1, assigns)

      # Should not contain the label text in a span
      refute html =~ "<span"
      # But title still exists
      assert html =~ "title=\"Close\""
    end

    test "renders with custom title and class" do
      assigns = %{phx_click: "close", title: "Dismiss", class: "custom-class"}
      html = render_component(&CloseButton.close_button/1, assigns)

      assert html =~ "title=\"Dismiss\""
      assert html =~ "custom-class"
    end
  end

  describe "StatusSwitch" do
    test "renders in checked state" do
      assigns = %{id: "switch-1", checked: true, on_change: "toggle"}
      html = render_component(&StatusSwitch.status_switch/1, assigns)

      assert html =~ "aria-checked"
      assert html =~ "status-toggle--active"
      assert html =~ "status-toggle-slider--active"
      # Active icon (checkmark) should be visible
      assert html =~ "status-toggle-icon--visible"
    end

    test "renders in unchecked state" do
      assigns = %{id: "switch-1", checked: false, on_change: "toggle"}
      html = render_component(&StatusSwitch.status_switch/1, assigns)

      # When false, aria-checked attribute is omitted by Phoenix
      refute html =~ "aria-checked"
      assert html =~ "status-toggle--inactive"
      refute html =~ "status-toggle-slider--active"
    end

    test "renders in disabled state" do
      assigns = %{id: "switch-1", checked: true, on_change: "toggle", disabled: true}
      html = render_component(&StatusSwitch.status_switch/1, assigns)

      assert html =~ "disabled"
      assert html =~ "opacity-50"
      assert html =~ "cursor-not-allowed"
    end

    test "renders with different sizes" do
      for size <- [:small, :medium, :large] do
        assigns = %{id: "switch-#{size}", checked: true, on_change: "toggle", size: size}
        html = render_component(&StatusSwitch.status_switch/1, assigns)
        assert html =~ "switch-#{size}"
      end
    end
  end

  describe "Toggle" do
    setup do
      options = [
        %{value: :list, label: "List View", icon: "list"},
        %{value: :grid, label: "Grid View", icon: "grid"}
      ]

      {:ok, options: options}
    end

    test "renders all options", %{options: options} do
      assigns = %{id: "toggle-1", active_option: :list, options: options, phx_click: "switch"}
      html = render_component(&Toggle.toggle/1, assigns)

      assert html =~ "List View"
      assert html =~ "Grid View"
      assert html =~ "toggle-1-list"
      assert html =~ "toggle-1-grid"
    end

    test "highlights active option", %{options: options} do
      assigns = %{id: "toggle-1", active_option: :grid, options: options, phx_click: "switch"}
      html = render_component(&Toggle.toggle/1, assigns)

      # Grid view button should have active class
      assert html =~ "toggle-1-grid"
      # The active option gets "btn-primary" class
      assert html =~ "btn-primary"
    end

    test "renders icons based on option", %{options: options} do
      assigns = %{id: "toggle-1", active_option: :list, options: options, phx_click: "switch"}
      html = render_component(&Toggle.toggle/1, assigns)

      # Should contain SVG paths for list and grid
      # list icon
      assert html =~ "M4 6h16M4 10h16M4 14h16M4 18h16"
      # grid icon
      assert html =~ "M4 6a2 2 0 012-2h2a2 2 0 012 2v2a2 2 0 01-2 2H6a2 2 0 01-2-2V6z"
    end

    test "renders with label", %{options: options} do
      assigns = %{
        id: "toggle-1",
        active_option: :list,
        options: options,
        phx_click: "switch",
        label: "View Mode"
      }

      html = render_component(&Toggle.toggle/1, assigns)

      assert html =~ "View Mode"
    end
  end

  describe "ToggleGroup" do
    setup do
      options = [
        %{value: :all, label: "All Items", short_label: "All"},
        %{value: :pending, label: "Pending Items", short_label: "Pending"}
      ]

      {:ok, options: options}
    end

    test "renders with labels and short labels", %{options: options} do
      assigns = %{id: "group-1", active_option: :all, options: options, on_change: "filter"}
      html = render_component(&ToggleGroup.toggle_group/1, assigns)

      assert html =~ "All Items"
      assert html =~ "Pending Items"
      assert html =~ "All"
      assert html =~ "Pending"
    end

    test "highlights active option", %{options: options} do
      assigns = %{id: "group-1", active_option: :pending, options: options, on_change: "filter"}
      html = render_component(&ToggleGroup.toggle_group/1, assigns)

      # Pending option should have active classes
      assert html =~ "btn-primary"
    end
  end

  describe "UIComponents" do
    test "action_button renders with variant and slots" do
      assigns = %{}

      inner_block = [
        %{__slot__: :inner_block, inner_block: fn _assigns, _index -> ~H"Click Me" end}
      ]

      component_assigns = %{
        variant: :danger,
        inner_block: inner_block
      }

      html = render_component(&UIComponents.action_button/1, component_assigns)
      assert html =~ "action-button--danger"
      assert html =~ "Click Me"
    end

    test "loading_button shows spinner when loading" do
      assigns = %{}

      inner_block = [
        %{__slot__: :inner_block, inner_block: fn _assigns, _index -> ~H"Submit" end}
      ]

      component_assigns = %{
        loading: true,
        loading_text: "Sending...",
        inner_block: inner_block
      }

      html = render_component(&UIComponents.loading_button/1, component_assigns)
      assert html =~ "spinner"
      assert html =~ "Sending..."
      refute html =~ "Submit"
    end

    test "calendar_day renders with various states" do
      day = %{day: 15, today: false, is_today: false}

      # Selected
      assigns = %{day: day, selected: true, available: true}
      html = render_component(&UIComponents.calendar_day/1, assigns)
      assert html =~ "calendar-day--selected"

      # Unavailable
      assigns = %{day: day, selected: false, available: false}
      html = render_component(&UIComponents.calendar_day/1, assigns)
      assert html =~ "calendar-day--unavailable"
      assert html =~ "disabled"

      # Today
      day_today = %{day: 15, today: true, is_today: true}
      assigns = %{day: day_today, selected: false, available: true}
      html = render_component(&UIComponents.calendar_day/1, assigns)
      assert html =~ "calendar-day--today"
    end
  end
end
