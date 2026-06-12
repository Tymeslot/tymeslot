defmodule TymeslotWeb.Components.CoreComponents.DropdownTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :utils

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias TymeslotWeb.Components.CoreComponents.Dropdown

  defp render_dropdown(extra \\ %{}) do
    assigns =
      Map.merge(
        %{
          id: "test-dd",
          open: false,
          on_toggle: "toggle",
          on_close: "close",
          target: nil,
          position: :bottom_end,
          trigger_class: nil,
          class: nil
        },
        extra
      )

    render_component(
      fn assigns ->
        ~H"""
        <Dropdown.dropdown
          id={@id}
          open={@open}
          on_toggle={@on_toggle}
          on_close={@on_close}
          target={@target}
          position={@position}
          trigger_class={@trigger_class}
          class={@class}
        >
          <:trigger>Open</:trigger>
          <:panel>Items</:panel>
        </Dropdown.dropdown>
        """
      end,
      assigns
    )
  end

  test "renders trigger button with on_toggle event" do
    html = render_dropdown()
    assert html =~ ~s(phx-click="toggle")
  end

  test "panel is absent when open is false" do
    html = render_dropdown(%{open: false})
    refute html =~ "Items"
  end

  test "panel is present when open is true" do
    html = render_dropdown(%{open: true})
    assert html =~ "Items"
  end

  test "phx-click-away is wired only when open" do
    open_html = render_dropdown(%{open: true})
    closed_html = render_dropdown(%{open: false})
    assert open_html =~ ~s(phx-click-away="close")
    refute closed_html =~ "phx-click-away"
  end

  test "panel has id derived from dropdown id" do
    html = render_dropdown(%{open: true})
    assert html =~ ~s(id="test-dd-panel")
  end

  test "trigger button has aria-controls linking to panel" do
    html = render_dropdown(%{open: true})
    assert html =~ ~s(aria-controls="test-dd-panel")
  end

  test "panel defaults to role=menu" do
    html = render_dropdown(%{open: true})
    assert html =~ ~s(role="menu")
  end

  test "panel role is configurable" do
    html =
      render_component(
        fn assigns ->
          ~H"""
          <Dropdown.dropdown
            id={@id}
            open={true}
            on_toggle={@on_toggle}
            on_close={@on_close}
            target={@target}
            position={@position}
            trigger_class={@trigger_class}
            class={@class}
            role="dialog"
          >
            <:trigger>Open</:trigger>
            <:panel>Items</:panel>
          </Dropdown.dropdown>
          """
        end,
        %{
          id: "test-dd",
          open: true,
          on_toggle: "toggle",
          on_close: "close",
          target: nil,
          position: :bottom_end,
          trigger_class: nil,
          class: nil
        }
      )

    assert html =~ ~s(role="dialog")
  end

  test "dialog panel receives an accessible name from panel_label" do
    html =
      render_component(
        fn assigns ->
          ~H"""
          <Dropdown.dropdown
            id={@id}
            open={true}
            on_toggle={@on_toggle}
            on_close={@on_close}
            target={@target}
            position={@position}
            trigger_class={@trigger_class}
            class={@class}
            role="dialog"
            panel_label="My Calendars"
          >
            <:trigger>Open</:trigger>
            <:panel>Items</:panel>
          </Dropdown.dropdown>
          """
        end,
        %{
          id: "test-dd",
          open: true,
          on_toggle: "toggle",
          on_close: "close",
          target: nil,
          position: :bottom_end,
          trigger_class: nil,
          class: nil
        }
      )

    # The accessible name lands on the panel element, alongside role="dialog".
    assert html =~ ~s(id="test-dd-panel")
    assert html =~ ~s(aria-label="My Calendars")
    assert html =~ ~s(role="dialog")
  end

  test "phx-window-keydown is bound when open" do
    html = render_dropdown(%{open: true})
    assert html =~ ~s(phx-window-keydown="close")
    assert html =~ ~s(phx-key="escape")
  end

  test "phx-window-keydown is not bound when closed" do
    html = render_dropdown(%{open: false})
    refute html =~ ~s(phx-window-keydown)
  end

  test "aria-expanded reflects open state" do
    open_html = render_dropdown(%{open: true})
    closed_html = render_dropdown(%{open: false})
    assert open_html =~ ~s(aria-expanded="true")
    assert closed_html =~ ~s(aria-expanded="false")
  end

  test "applies bottom_end position classes by default" do
    html = render_dropdown(%{open: true})
    assert html =~ "right-0 top-full mt-1"
  end

  test "applies top_start position classes" do
    html = render_dropdown(%{open: true, position: :top_start})
    assert html =~ "left-0 bottom-full mb-1"
  end

  test "extra panel class is applied" do
    html = render_dropdown(%{open: true, class: "w-64 my-custom"})
    assert html =~ "my-custom"
  end

  test "phx-target is on trigger button when target provided" do
    html = render_dropdown(%{target: "#comp"})
    assert html =~ ~s(phx-target="#comp")
  end

  test "phx-target is on container and trigger regardless of open state" do
    open_html = render_dropdown(%{open: true, target: "#comp"})
    closed_html = render_dropdown(%{open: false, target: "#comp"})
    # container + button = 2 occurrences in both states, split into 3 parts
    assert length(String.split(open_html, ~s(phx-target="#comp"))) == 3
    assert length(String.split(closed_html, ~s(phx-target="#comp"))) == 3
  end

  test "dropdown_item renders label" do
    html =
      render_component(
        fn assigns ->
          ~H"""
          <Dropdown.dropdown_item label="Settings" href="/settings" />
          """
        end,
        %{}
      )

    assert html =~ "Settings"
    assert html =~ ~s(role="menuitem")
  end

  test "dropdown_item renders a link when href is given" do
    html =
      render_component(
        fn assigns ->
          ~H"""
          <Dropdown.dropdown_item label="Settings" href="/settings" />
          """
        end,
        %{}
      )

    assert html =~ "<a"
    refute html =~ "<button"
  end

  test "dropdown_item renders a button when no navigation attr is given" do
    html =
      render_component(
        fn assigns ->
          ~H"""
          <Dropdown.dropdown_item label="Action" phx-click="do_thing" />
          """
        end,
        %{}
      )

    assert html =~ ~s(<button type="button")
    refute html =~ "<a"
  end

  test "dropdown_item applies danger modifier class" do
    html =
      render_component(
        fn assigns ->
          ~H"""
          <Dropdown.dropdown_item label="Delete" danger={true} href="/delete" />
          """
        end,
        %{}
      )

    assert html =~ "dropdown-item--danger"
  end

  test "dropdown_divider renders separator" do
    html =
      render_component(
        fn assigns ->
          ~H"""
          <Dropdown.dropdown_divider />
          """
        end,
        %{}
      )

    assert html =~ ~s(role="separator")
  end

  test "applies bottom_start position classes" do
    html = render_dropdown(%{open: true, position: :bottom_start})
    assert html =~ "left-0 top-full mt-1"
  end

  test "applies top_end position classes" do
    html = render_dropdown(%{open: true, position: :top_end})
    assert html =~ "right-0 bottom-full mb-1"
  end

  test "trigger_class is applied to the trigger button" do
    html = render_dropdown(%{trigger_class: "my-test-trigger"})
    assert html =~ ~s(class="my-test-trigger")
  end

  test "dropdown_item renders icon element when icon is given" do
    html =
      render_component(
        fn assigns ->
          ~H"""
          <Dropdown.dropdown_item label="Foo" icon="hero-cog-6-tooth" href="/foo" />
          """
        end,
        %{}
      )

    assert html =~ "hero-cog-6-tooth"
    assert html =~ "dropdown-item__icon"
  end

  test "dropdown_item renders icon alongside danger modifier" do
    html =
      render_component(
        fn assigns ->
          ~H"""
          <Dropdown.dropdown_item label="Delete" icon="hero-trash" danger={true} href="/delete" />
          """
        end,
        %{}
      )

    assert html =~ "dropdown-item--danger"
    assert html =~ "dropdown-item__icon"
  end
end
