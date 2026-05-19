defmodule TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.YesNoTest do
  use ExUnit.Case, async: true

  @moduletag :custom_fields

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.YesNo

  defp render_input(definition, value \\ nil) do
    render_component(&YesNo.render/1, definition: definition, value: value, myself: nil)
  end

  test "renders two radios with Yes and No labels" do
    html = render_input(%{"type" => "yes_no", "label" => "Attending?"})

    assert html =~ ~s(type="radio")
    assert html =~ ~s(value="true")
    assert html =~ ~s(value="false")
    assert html =~ "Yes"
    assert html =~ "No"
  end

  test "leaves both radios unchecked when no answer has been given" do
    html = render_input(%{"type" => "yes_no", "label" => "Attending?"})
    refute html =~ "checked"
  end

  test "marks the Yes radio when the answer is true" do
    html = render_input(%{"type" => "yes_no", "label" => "Attending?"}, true)

    assert html =~ ~r/<input[^>]*value="true"[^>]*checked/
    refute html =~ ~r/<input[^>]*value="false"[^>]*checked/
  end

  test "marks the No radio when the answer is false" do
    html = render_input(%{"type" => "yes_no", "label" => "Attending?"}, false)

    assert html =~ ~r/<input[^>]*value="false"[^>]*checked/
    refute html =~ ~r/<input[^>]*value="true"[^>]*checked/
  end

  test "renders a tile per answer so the choice reads as a card pair, not a button row" do
    html = render_input(%{"type" => "yes_no", "label" => "Attending?"})

    assert html =~ ~s(class="custom-question-yes-no)
    assert html =~ "is-yes"
    assert html =~ "is-no"
    # An svg glyph accompanies each tile so the choice is recognisable at a glance.
    assert html =~ "<svg"
  end

  test "highlights only the selected tile with is-selected" do
    yes_html = render_input(%{"type" => "yes_no", "label" => "Attending?"}, true)
    no_html = render_input(%{"type" => "yes_no", "label" => "Attending?"}, false)

    assert yes_html =~ ~r/is-yes[^"]*is-selected/
    refute yes_html =~ ~r/is-no[^"]*is-selected/

    assert no_html =~ ~r/is-no[^"]*is-selected/
    refute no_html =~ ~r/is-yes[^"]*is-selected/
  end
end
