defmodule TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.TimeTest do
  use ExUnit.Case, async: true

  @moduletag :custom_fields

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.Time

  defp render_input(definition, value \\ nil) do
    render_component(&Time.render/1, definition: definition, value: value, myself: nil)
  end

  test "renders the time picker inside the answer form, posting as value" do
    html = render_input(%{"id" => "q1", "type" => "time", "label" => "Arrival"})

    assert html =~ ~s(phx-hook="DateTimePicker")
    assert html =~ ~s(phx-change="answer")
    assert html =~ ~s(name="value")
  end

  test "posts the 24-hour value and shows it in the visitor's clock" do
    html = render_input(%{"id" => "q1", "type" => "time", "label" => "Arrival"}, "14:30")

    assert html =~ ~s(value="14:30")
    assert html =~ ~s(value="2:30 PM")
  end

  test "passes the question's limits to the picker" do
    html =
      render_input(%{
        "id" => "q1",
        "type" => "time",
        "label" => "Arrival",
        "min" => "09:00",
        "max" => "17:00"
      })

    assert html =~ ~s(min="09:00")
    assert html =~ ~s(max="17:00")
  end
end
