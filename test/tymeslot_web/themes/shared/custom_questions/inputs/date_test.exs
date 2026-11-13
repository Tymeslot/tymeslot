defmodule TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.DateTest do
  use ExUnit.Case, async: true

  @moduletag :custom_fields

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.Date

  defp render_input(definition, value \\ nil) do
    render_component(&Date.render/1, definition: definition, value: value, myself: nil)
  end

  test "renders the date picker inside the answer form, posting as value" do
    html = render_input(%{"id" => "q1", "type" => "date", "label" => "Birthday"})

    assert html =~ ~s(phx-hook="DateTimePicker")
    assert html =~ ~s(phx-change="answer")
    assert html =~ ~s(name="value")
    assert html =~ ~s(data-fact="answer")
  end

  test "posts the ISO value and shows it in the visitor's language" do
    html = render_input(%{"id" => "q1", "type" => "date", "label" => "Birthday"}, "1990-05-19")

    assert html =~ ~s(value="1990-05-19")
    assert html =~ ~s(value="19 May 1990")
  end

  test "keeps a question's accessible name and limits" do
    html =
      render_input(%{
        "id" => "q1",
        "type" => "date",
        "label" => "Birthday",
        "min" => "2026-01-01",
        "required" => true
      })

    assert html =~ "Birthday"
    assert html =~ ~s(aria-required="true")
    assert html =~ ~s(min="2026-01-01")
  end
end
