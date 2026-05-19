defmodule TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.NumberTest do
  use ExUnit.Case, async: true

  @moduletag :custom_fields

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.Number

  defp render_input(definition, value \\ nil) do
    render_component(&Number.render/1, definition: definition, value: value, myself: nil)
  end

  test "renders an HTML5 number input" do
    html = render_input(%{"type" => "number", "label" => "Age"})
    assert html =~ ~s(type="number")
    assert html =~ ~s(phx-blur="answer")
  end

  test "renders the provided numeric value" do
    html = render_input(%{"type" => "number", "label" => "Age"}, 42)
    assert html =~ ~s(value="42")
  end
end
