defmodule TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.PhoneTest do
  use ExUnit.Case, async: true

  @moduletag :custom_fields

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.Phone

  defp render_input(definition, value \\ nil) do
    render_component(&Phone.render/1, definition: definition, value: value, myself: nil)
  end

  test "renders an HTML5 tel input" do
    html = render_input(%{"type" => "phone", "label" => "Mobile"})
    assert html =~ ~s(type="tel")
    assert html =~ ~s(phx-blur="answer")
  end

  test "renders the provided value" do
    html = render_input(%{"type" => "phone", "label" => "Mobile"}, "+44 7700 900123")
    assert html =~ "+44 7700 900123"
  end
end
