defmodule TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.TimeTest do
  use ExUnit.Case, async: true

  @moduletag :custom_fields

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.Time

  defp render_input(definition, value \\ nil) do
    render_component(&Time.render/1, definition: definition, value: value, myself: nil)
  end

  test "renders an HTML5 time input" do
    html = render_input(%{"type" => "time", "label" => "Preferred time"})
    assert html =~ ~s(type="time")
    assert html =~ ~s(phx-change="answer")
  end

  test "renders the provided value" do
    html = render_input(%{"type" => "time", "label" => "Preferred time"}, "09:30")
    assert html =~ ~s(value="09:30")
  end
end
