defmodule TymeslotWeb.Components.UITest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :utils

  import Phoenix.LiveViewTest
  import Phoenix.Component
  alias TymeslotWeb.Components.CoreComponents.Buttons
  alias TymeslotWeb.Components.UI.StatusSwitch

  describe "StatusSwitch" do
    test "renders in checked state" do
      assigns = %{id: "switch-1", checked: true, on_change: "toggle"}
      html = render_component(&StatusSwitch.status_switch/1, assigns)

      assert html =~ ~s(aria-checked="true")
      assert html =~ "status-toggle--active"
      # The slider has travelled to the "on" end of the medium track.
      assert "translate-x-5" in slider_classes(html)
      # Active icon (checkmark) should be visible
      assert html =~ "status-toggle-icon--visible"
    end

    test "renders in unchecked state" do
      assigns = %{id: "switch-1", checked: false, on_change: "toggle"}
      html = render_component(&StatusSwitch.status_switch/1, assigns)

      # `role="switch"` is only meaningful with an explicit aria-checked, so the
      # false case has to render the attribute rather than drop it. Interpolating
      # the boolean directly omits it, which reads to assistive tech as a switch
      # with no state at all.
      assert html =~ ~s(aria-checked="false")
      assert html =~ "status-toggle--inactive"
      # The slider rests at the "off" end: no travel at all.
      refute Enum.any?(slider_classes(html), &String.starts_with?(&1, "translate-x-"))
    end

    test "renders an explicit button type so it can sit inside a form" do
      assigns = %{id: "switch-1", checked: false, on_change: "toggle"}
      html = render_component(&StatusSwitch.status_switch/1, assigns)

      # A bare <button> in a form defaults to type="submit", so without this the
      # switch would submit the surrounding form instead of toggling.
      assert html =~ ~s(type="button")
    end

    test "renders in disabled state" do
      assigns = %{id: "switch-1", checked: true, on_change: "toggle", disabled: true}
      html = render_component(&StatusSwitch.status_switch/1, assigns)

      assert html =~ "disabled"
      assert html =~ "opacity-50"
      assert html =~ "cursor-not-allowed"
    end

    # {track dimensions, slider dimensions} per size. The id echoes the size
    # name, so asserting on the id proves nothing about the size variant
    # actually reaching the class list.
    @switch_sizes %{
      small: {"h-5 w-9", "h-4 w-4"},
      medium: {"h-6 w-11", "h-5 w-5"},
      large: {"h-7 w-12", "h-6 w-6"}
    }

    test "each size renders its own track and slider dimensions" do
      for {size, {track, slider}} <- @switch_sizes do
        assigns = %{id: "switch-#{size}", checked: true, on_change: "toggle", size: size}
        html = render_component(&StatusSwitch.status_switch/1, assigns)

        assert html =~ track
        assert html =~ slider

        for {_other_size, {other_track, _slider}} <- Map.delete(@switch_sizes, size) do
          refute html =~ other_track
        end
      end
    end

    # The slider's travel is the track's inner width less the slider: the small
    # track has 1px borders, the others 2px, so a single shared travel would run
    # the small slider past its track.
    test "each size moves the slider exactly across its own track" do
      travels = %{small: "translate-x-4.5", medium: "translate-x-5", large: "translate-x-5"}

      for {size, travel} <- travels do
        on =
          render_component(&StatusSwitch.status_switch/1, %{
            id: "on",
            checked: true,
            on_change: "toggle",
            size: size
          })

        off =
          render_component(&StatusSwitch.status_switch/1, %{
            id: "off",
            checked: false,
            on_change: "toggle",
            size: size
          })

        assert travel in slider_classes(on)
        refute off =~ "translate-x-"
      end
    end
  end

  describe "Buttons" do
    test "action_button renders with variant and slots" do
      assigns = %{}

      inner_block = [
        %{__slot__: :inner_block, inner_block: fn _assigns, _index -> ~H"Click Me" end}
      ]

      component_assigns = %{
        variant: :danger,
        inner_block: inner_block
      }

      html = render_component(&Buttons.action_button/1, component_assigns)
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

      html = render_component(&Buttons.loading_button/1, component_assigns)
      assert html =~ "spinner"
      assert html =~ "Sending..."
      refute html =~ "Submit"
    end
  end

  defp slider_classes(html) do
    [class] = html |> Floki.parse_fragment!() |> Floki.attribute(".status-toggle-slider", "class")
    String.split(class)
  end
end
