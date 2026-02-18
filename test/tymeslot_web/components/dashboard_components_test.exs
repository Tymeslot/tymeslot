defmodule TymeslotWeb.Components.DashboardComponentsTest do
  @moduletag :utils
  use TymeslotWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Phoenix.Component
  alias Floki
  alias Phoenix.LiveView.JS
  alias TymeslotWeb.Components.CoreComponents
  alias TymeslotWeb.Components.DashboardComponents

  test "form_input renders correctly" do
  @moduletag :utils
    assigns = %{
      id: "test-input",
      name: "test_name",
      label: "Test Label",
      value: "test value",
      placeholder: "Enter something",
      help: "Some help text"
    }

    html = render_component(&DashboardComponents.form_input/1, assigns)
    doc = Floki.parse_document!(html)

    assert Floki.text(Floki.find(doc, "label[for='test-input']")) =~ "Test Label"

    assert Floki.find(doc, "input#test-input[name='test_name'][placeholder='Enter something']") !=
             []

    assert Floki.find(doc, "input#test-input.input") != []
    assert html =~ "test value"
    assert Floki.text(doc) =~ "Some help text"
  end

  test "form_input does not render help when nil" do
    assigns = %{
      id: "test-input",
      name: "test_name",
      label: "Test Label",
      value: "test value",
      placeholder: "Enter something",
      help: nil
    }

    html = render_component(&DashboardComponents.form_input/1, assigns)
    doc = Floki.parse_document!(html)

    assert Floki.find(doc, "p") == []
  end

  test "form_input accepts nil value" do
    assigns = %{
      id: "test-input",
      name: "test_name",
      label: "Test Label",
      value: nil,
      placeholder: "Enter something"
    }

    html = render_component(&DashboardComponents.form_input/1, assigns)
    doc = Floki.parse_document!(html)

    assert Floki.find(doc, "input#test-input[name='test_name']") != []
  end

  test "form_select renders correctly" do
    assigns = %{
      id: "test-select",
      name: "test_select",
      label: "Select Option",
      value: "opt2",
      options: [{"Option 1", "opt1"}, {"Option 2", "opt2"}],
      help: "Select one"
    }

    html = render_component(&DashboardComponents.form_select/1, assigns)
    doc = Floki.parse_document!(html)

    assert Floki.text(Floki.find(doc, "label[for='test-select']")) =~ "Select Option"
    assert Floki.find(doc, "select#test-select[name='test_select']") != []
    assert Floki.text(doc) =~ "Select one"

    assert length(Floki.find(doc, "select#test-select option")) == 2

    selected = Floki.find(doc, "select#test-select option[selected]")
    assert length(selected) == 1
    assert selected |> List.first() |> Floki.attribute("value") == ["opt2"]
  end

  test "form_select renders with no selection when value not in options" do
    assigns = %{
      id: "test-select",
      name: "test_select",
      label: "Select Option",
      value: "missing",
      options: [{"Option 1", "opt1"}, {"Option 2", "opt2"}]
    }

    html = render_component(&DashboardComponents.form_select/1, assigns)
    doc = Floki.parse_document!(html)

    assert Floki.find(doc, "select#test-select option[selected]") == []
  end

  test "integration_card renders correctly" do
    assigns = %{}

    action_slot = [
      %{
        __slot__: :action,
        inner_block: fn _assigns, _changes ->
          ~H"""
          <button id="action-btn">Action</button>
          """
        end
      }
    ]

    component_assigns = %{
      title: "Integration Title",
      subtitle: "Integration Subtitle",
      details: ["Detail 1", "Detail 2"],
      action: action_slot
    }

    html = render_component(&DashboardComponents.integration_card/1, component_assigns)
    doc = Floki.parse_document!(html)

    assert html =~ "Integration Title"
    assert html =~ "Integration Subtitle"
    assert html =~ "Detail 1"
    assert html =~ "Detail 2"
    assert Floki.find(doc, "#action-btn") != []
  end

  test "empty_state renders correctly" do
    assigns = %{}

    icon_slot = [
      %{
        __slot__: :icon,
        inner_block: fn _assigns, _changes ->
          ~H"""
          <path d="M12 2L2 12h10v10l10-10H12V2z" />
          """
        end
      }
    ]

    action_slot = [
      %{
        __slot__: :action,
        inner_block: fn _assigns, _changes ->
          ~H"""
          <button id="empty-action">Add New</button>
          """
        end
      }
    ]

    component_assigns = %{
      message: "No data found",
      icon: icon_slot,
      action: action_slot
    }

    html = render_component(&DashboardComponents.empty_state/1, component_assigns)
    doc = Floki.parse_document!(html)

    assert html =~ "No data found"
    assert html =~ "M12 2L2 12h10v10l10-10H12V2z"
    assert Floki.find(doc, "#empty-action") != []
  end

  test "empty_state renders without action slot" do
    assigns = %{}

    icon_slot = [
      %{
        __slot__: :icon,
        inner_block: fn _assigns, _changes ->
          ~H"""
          <path d="M12 2L2 12h10v10l10-10H12V2z" />
          """
        end
      }
    ]

    component_assigns = %{
      message: "No data found",
      icon: icon_slot
    }

    html = render_component(&DashboardComponents.empty_state/1, component_assigns)
    doc = Floki.parse_document!(html)

    assert Floki.text(doc) =~ "No data found"
    assert Floki.find(doc, "button") == []
    assert Floki.find(doc, "svg[aria-hidden='true']") != []
  end

  test "empty_state is robust to action: nil" do
    assigns = %{}

    icon_slot = [
      %{
        __slot__: :icon,
        inner_block: fn _assigns, _changes ->
          ~H"""
          <path d="M12 2L2 12h10v10l10-10H12V2z" />
          """
        end
      }
    ]

    component_assigns = %{
      message: "No data found",
      icon: icon_slot,
      action: nil
    }

    html = render_component(&DashboardComponents.empty_state/1, component_assigns)
    doc = Floki.parse_document!(html)

    assert Floki.text(doc) =~ "No data found"
    assert Floki.find(doc, "button") == []
  end

  test "empty_state uses icon_title for accessible SVG" do
    assigns = %{}

    icon_slot = [
      %{
        __slot__: :icon,
        inner_block: fn _assigns, _changes ->
          ~H"""
          <path d="M12 2L2 12h10v10l10-10H12V2z" />
          """
        end
      }
    ]

    component_assigns = %{
      message: "No data found",
      icon: icon_slot,
      icon_title: "Empty state icon"
    }

    html = render_component(&DashboardComponents.empty_state/1, component_assigns)
    doc = Floki.parse_document!(html)

    assert Floki.find(doc, "svg[role='img'][aria-label='Empty state icon']") != []
    assert Floki.text(Floki.find(doc, "svg title")) =~ "Empty state icon"
  end

  test "button renders correctly" do
    assigns = %{}

    inner_block = [
      %{__slot__: :inner_block, inner_block: fn _assigns, _changes -> ~H"Save Changes" end}
    ]

    component_assigns = %{
      type: "submit",
      variant: :primary,
      rest: %{id: "submit-btn", "phx-click": "save"},
      inner_block: inner_block
    }

    html = render_component(&DashboardComponents.button/1, component_assigns)
    doc = Floki.parse_document!(html)

    assert Floki.find(doc, "button#submit-btn[type='submit'].btn-primary[phx-click='save']") != []
    assert Floki.text(doc) =~ "Save Changes"
  end

  test "stat_card renders correctly" do
    assigns = %{
      title: "Active Meetings",
      value: 15,
      icon: "calendar",
      link: "/dashboard/meetings",
      description: "Confirmed meetings for this week"
    }

    html = render_component(&DashboardComponents.stat_card/1, assigns)

    assert html =~ "Active Meetings"
    assert html =~ "15"
    assert html =~ "/dashboard/meetings"
    assert html =~ "Confirmed meetings for this week"
  end

  test "section_header renders correctly" do
    assigns = %{
      icon: :calendar,
      title: "My Availability",
      count: 5,
      saving: true
    }

    html = render_component(&CoreComponents.section_header/1, assigns)

    assert html =~ "My Availability"
    assert html =~ "5"
    assert html =~ "Saving changes..."
    assert html =~ "animate-spin"
  end

  test "section_header omits count badge and saving indicator when not set" do
    assigns = %{
      icon: :calendar,
      title: "My Availability",
      count: nil,
      saving: false
    }

    html = render_component(&CoreComponents.section_header/1, assigns)
    doc = Floki.parse_document!(html)

    assert Floki.text(doc) =~ "My Availability"
    refute html =~ "Saving..."
    assert Floki.find(doc, "span.bg-turquoise-100") == []
  end

  test "confirmation_modal renders correctly" do
    assigns = %{
      id: "confirm-delete",
      show: true,
      title: "Delete Item",
      message: "Are you sure you want to delete this?",
      on_cancel: %JS{},
      on_confirm: "delete_item",
      confirm_text: "Yes, Delete",
      confirm_variant: :danger
    }

    html = render_component(&DashboardComponents.confirmation_modal/1, assigns)
    doc = Floki.parse_document!(html)

    assert html =~ "confirm-delete"
    assert html =~ "Delete Item"
    assert html =~ "Are you sure you want to delete this?"
    assert html =~ "Yes, Delete"
    assert Floki.find(doc, "button[phx-click='delete_item']") != []
  end

  test "confirmation_modal hides when show is false" do
    assigns = %{
      id: "confirm-delete",
      show: false,
      title: "Delete Item",
      message: "Are you sure you want to delete this?",
      on_cancel: %JS{},
      on_confirm: "delete_item"
    }

    html = render_component(&DashboardComponents.confirmation_modal/1, assigns)
    doc = Floki.parse_document!(html)

    # Core modal uses inline style for visibility
    assert Floki.attribute(doc, "div#confirm-delete", "style") == ["display: none;"]
  end
end
