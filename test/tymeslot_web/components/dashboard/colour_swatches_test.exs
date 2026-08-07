defmodule TymeslotWeb.Components.Dashboard.ColourSwatchesTest do
  @moduledoc """
  The shared palette picker, which several rows of the calendars dropdown stack
  one above another.

  Its layout rules are the point rather than an implementation detail: the
  clearing control is the same shape and size as the colours and comes last, so
  stacked pickers line up on one grid. A wide text pill placed first, which is
  what this replaced, pushed each row's swatches to a different offset.
  """
  use TymeslotWeb.ConnCase, async: true

  @moduletag :components

  import Phoenix.LiveViewTest

  alias Tymeslot.Integrations.Calendar.EventColour
  alias TymeslotWeb.Components.Dashboard.ColourSwatches

  defp render_swatches(selected) do
    render_component(&ColourSwatches.colour_swatches/1, %{
      selected: selected,
      event: "set_colour",
      target: %Phoenix.LiveComponent.CID{cid: 1},
      group_label: "Colour for Work"
    })
  end

  defp buttons(html) do
    html |> Floki.parse_document!() |> Floki.find("button")
  end

  defp colour_order(html) do
    html |> buttons() |> Floki.attribute("phx-value-colour")
  end

  defp pressed(html) do
    html
    |> buttons()
    |> Enum.filter(&(Floki.attribute(&1, "aria-pressed") == ["true"]))
    |> Enum.flat_map(&Floki.attribute(&1, "phx-value-colour"))
  end

  test "offers every palette colour plus the clearing swatch" do
    assert Enum.sort(colour_order(render_swatches(nil))) ==
             Enum.sort(["default" | EventColour.keys()])
  end

  test "puts the clearing swatch last so stacked pickers line up" do
    assert List.last(colour_order(render_swatches(nil))) == "default"
  end

  test "sizes the clearing swatch like the colours beside it" do
    # Same grid or the rows do not align, which was the whole complaint.
    sizes =
      render_swatches(nil)
      |> buttons()
      |> Enum.map(fn button ->
        button |> Floki.attribute("class") |> Enum.join(" ") |> String.contains?("w-6 h-6")
      end)

    assert Enum.all?(sizes)
  end

  test "presses the clearing swatch when nothing is stored" do
    assert pressed(render_swatches(nil)) == ["default"]
  end

  test "presses the stored colour and nothing else" do
    assert pressed(render_swatches("grape")) == ["grape"]
  end

  test "gives the clearing swatch an accessible name" do
    # It renders an icon and no text, so without this it is an unlabelled
    # button to anyone not looking at it.
    [label] =
      render_swatches(nil)
      |> buttons()
      |> Enum.filter(&(Floki.attribute(&1, "phx-value-colour") == ["default"]))
      |> Floki.attribute("aria-label")

    assert label =~ "Default colour"
  end
end
