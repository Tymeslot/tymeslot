defmodule TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.RendererTest do
  use ExUnit.Case, async: true

  @moduletag :custom_fields

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.Renderer

  # The behaviour of each input is covered by its sibling test module
  # (e.g. `YesNoTest`, `SingleSelectTest`). These tests verify only that
  # the dispatcher routes each known type to a renderer that produces
  # the expected family of HTML — guarding against a clause being
  # forgotten when a new type is added.

  defp render_input(definition) do
    render_component(&Renderer.render/1,
      definition: definition,
      value: nil,
      myself: nil
    )
  end

  test "dispatches short_text to a text input" do
    assert render_input(%{"type" => "short_text", "label" => "x"}) =~ ~s(type="text")
  end

  test "dispatches number to a number input" do
    assert render_input(%{"type" => "number", "label" => "x"}) =~ ~s(type="number")
  end

  test "dispatches phone to a tel input" do
    assert render_input(%{"type" => "phone", "label" => "x"}) =~ ~s(type="tel")
  end

  test "dispatches url to a url input" do
    assert render_input(%{"type" => "url", "label" => "x"}) =~ ~s(type="url")
  end

  test "dispatches date to a date input" do
    assert render_input(%{"type" => "date", "label" => "x"}) =~ ~s(type="date")
  end

  test "dispatches time to a time input" do
    assert render_input(%{"type" => "time", "label" => "x"}) =~ ~s(type="time")
  end

  test "dispatches yes_no to a radio group" do
    html = render_input(%{"type" => "yes_no", "label" => "x"})
    assert html =~ ~s(type="radio")
    assert html =~ "Yes"
    assert html =~ "No"
  end

  test "dispatches single_select to a radio group when options fit" do
    d = %{
      "type" => "single_select",
      "label" => "x",
      "options" => [%{"key" => "a", "label" => "A"}]
    }

    assert render_input(d) =~ ~s(type="radio")
  end

  test "dispatches multi_select to a checkbox group" do
    d = %{
      "type" => "multi_select",
      "label" => "x",
      "options" => [%{"key" => "a", "label" => "A"}]
    }

    assert render_input(d) =~ ~s(type="checkbox")
  end

  test "dispatches note to the acknowledgement layout" do
    d = %{"type" => "note", "label" => "x", "body" => "Please read."}
    assert render_input(d) =~ ~s(phx-value-value="acknowledge")
  end
end
