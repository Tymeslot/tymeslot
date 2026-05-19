defmodule TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.MultiSelectTest do
  use ExUnit.Case, async: true

  @moduletag :custom_fields

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.MultiSelect

  defp render_input(definition, value \\ nil) do
    render_component(&MultiSelect.render/1, definition: definition, value: value, myself: nil)
  end

  defp toppings do
    %{
      "type" => "multi_select",
      "label" => "Toppings",
      "options" => [
        %{"key" => "cheese", "label" => "Cheese"},
        %{"key" => "olives", "label" => "Olives"},
        %{"key" => "ham", "label" => "Ham"}
      ]
    }
  end

  test "renders one checkbox per option" do
    html = render_input(toppings())

    assert html =~ ~s(type="checkbox")
    assert html =~ "Cheese"
    assert html =~ "Olives"
    assert html =~ "Ham"
  end

  test "marks the checkboxes whose keys are in the selected list" do
    html = render_input(toppings(), ["cheese", "ham"])

    assert html =~ ~r/<input[^>]*value="cheese"[^>]*checked/
    assert html =~ ~r/<input[^>]*value="ham"[^>]*checked/
    refute html =~ ~r/<input[^>]*value="olives"[^>]*checked/
  end

  test "treats a nil value as an empty selection" do
    html = render_input(toppings(), nil)
    refute html =~ "checked"
  end
end
