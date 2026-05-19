defmodule TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.DateTest do
  use ExUnit.Case, async: true

  @moduletag :custom_fields

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.Date

  defp render_input(definition, value \\ nil) do
    render_component(&Date.render/1, definition: definition, value: value, myself: nil)
  end

  test "renders an HTML5 date input" do
    html = render_input(%{"type" => "date", "label" => "Birthday"})
    assert html =~ ~s(type="date")
    assert html =~ ~s(phx-blur="answer")
  end

  test "renders the provided value" do
    html = render_input(%{"type" => "date", "label" => "Birthday"}, "1990-05-19")
    assert html =~ ~s(value="1990-05-19")
  end
end
