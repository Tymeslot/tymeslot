defmodule TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.ShortTextTest do
  use ExUnit.Case, async: true

  @moduletag :custom_fields

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.ShortText

  defp render_input(definition, value \\ nil) do
    render_component(&ShortText.render/1, definition: definition, value: value, myself: nil)
  end

  test "renders an HTML5 text input wired to the answer event" do
    html = render_input(%{"type" => "short_text", "label" => "Company"})

    assert html =~ ~s(type="text")
    assert html =~ ~s(name="value")
    assert html =~ ~s(phx-blur="answer")
  end

  test "debounces input until blur and disables browser autocomplete" do
    html = render_input(%{"type" => "short_text", "label" => "Company"})

    assert html =~ ~s(phx-debounce="blur")
    assert html =~ ~s(autocomplete="off")
  end

  test "exposes label and required state to assistive tech" do
    html = render_input(%{"type" => "short_text", "label" => "Company", "required" => true})

    assert html =~ ~s(aria-label="Company")
    assert html =~ ~s(aria-required="true")
  end

  test "renders the provided value" do
    html = render_input(%{"type" => "short_text", "label" => "Company"}, "Acme")

    assert html =~ ~s(value="Acme")
  end
end
