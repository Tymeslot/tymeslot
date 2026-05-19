# credo:disable-for-this-file CredoChecks.UseCoreInputs
defmodule TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.SingleSelectTest do
  use ExUnit.Case, async: true

  @moduletag :custom_fields

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.SingleSelect

  defp render_input(definition, value \\ nil) do
    render_component(&SingleSelect.render/1, definition: definition, value: value, myself: nil)
  end

  defp options(n) do
    for i <- 1..n, do: %{"key" => "k#{i}", "label" => "Option #{i}"}
  end

  test "renders as a radio group when there are five or fewer options" do
    d = %{"type" => "single_select", "label" => "Pick", "options" => options(3)}
    html = render_input(d)

    assert html =~ ~s(type="radio")
    refute html =~ "<select"
  end

  test "marks the matching radio when a value is selected" do
    d = %{
      "type" => "single_select",
      "label" => "Pick",
      "options" => [
        %{"key" => "red", "label" => "Red"},
        %{"key" => "blue", "label" => "Blue"}
      ]
    }

    html = render_input(d, "blue")

    assert html =~ ~r/<input[^>]*value="blue"[^>]*checked/
    refute html =~ ~r/<input[^>]*value="red"[^>]*checked/
  end

  test "falls back to a <select> when there are more than five options" do
    d = %{"type" => "single_select", "label" => "Pick", "options" => options(6)}
    html = render_input(d, "k3")

    assert html =~ "<select"
    assert html =~ ~r/<option value="k3"[^>]*selected/
    refute html =~ ~s(type="radio")
  end

  test "the select fallback includes an empty placeholder option" do
    d = %{"type" => "single_select", "label" => "Pick", "options" => options(6)}
    html = render_input(d)

    assert html =~ ~s(<option value="">)
  end
end
