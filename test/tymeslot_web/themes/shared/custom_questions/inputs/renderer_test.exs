defmodule TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.RendererTest do
  use ExUnit.Case, async: true

  @moduletag :custom_fields

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.Renderer

  # The behaviour of each input is covered by its sibling test module
  # (e.g. `YesNoTest`, `SingleSelectTest`). These tests verify only that
  # the dispatcher routes each known type to a renderer that produces
  # the expected family of HTML — guarding against a clause being
  # forgotten when a new type is added.

  defp render_input(definition) do
    render_component(&Renderer.render/1,
      definition: definition,
      value: nil,
      myself: nil
    )
  end

  test "dispatches short_text to a text input" do
    assert render_input(%{"type" => "short_text", "label" => "x"}) =~ ~s(type="text")
  end

  test "dispatches number to a number input" do
    assert render_input(%{"type" => "number", "label" => "x"}) =~ ~s(type="number")
  end

  test "dispatches phone to a tel input" do
    assert render_input(%{"type" => "phone", "label" => "x"}) =~ ~s(type="tel")
  end

  test "dispatches url to a url input" do
    assert render_input(%{"type" => "url", "label" => "x"}) =~ ~s(type="url")
  end

  test "dispatches date to a date input" do
    assert render_input(%{"type" => "date", "label" => "x"}) =~ ~s(type="date")
  end

  test "dispatches time to a time input" do
    assert render_input(%{"type" => "time", "label" => "x"}) =~ ~s(type="time")
  end

  test "dispatches yes_no to a radio group" do
    html = render_input(%{"type" => "yes_no", "label" => "x"})
    assert html =~ ~s(type="radio")
    assert html =~ "Yes"
    assert html =~ "No"
  end

  test "dispatches single_select to a radio group when options fit" do
    d = %{
      "type" => "single_select",
      "label" => "x",
      "options" => [%{"key" => "a", "label" => "A"}]
    }

    assert render_input(d) =~ ~s(type="radio")
  end

  test "dispatches multi_select to a checkbox group" do
    d = %{
      "type" => "multi_select",
      "label" => "x",
      "options" => [%{"key" => "a", "label" => "A"}]
    }

    assert render_input(d) =~ ~s(type="checkbox")
  end

  test "dispatches note to the acknowledgement layout" do
    d = %{"type" => "note", "label" => "x", "body" => "Please read."}
    assert render_input(d) =~ ~s(phx-value-value="acknowledge")
  end

  describe "the inputs' own lines" do
    @note %{"type" => "note", "label" => "x", "body" => "Please read."}
    @select %{
      "type" => "single_select",
      "label" => "x",
      "options" => for(i <- 1..6, do: %{"key" => "k#{i}", "label" => "Option #{i}"})
    }
    @yes_no %{"type" => "yes_no", "label" => "x"}

    defp render_in(definition, theme_key) do
      render_component(&Renderer.render/1,
        definition: definition,
        value: nil,
        myself: nil,
        theme_key: theme_key
      )
    end

    defp prompt_option(html) do
      html |> Floki.parse_fragment!() |> Floki.find("option[value='']") |> Floki.text()
    end

    defp yes_no_labels(html) do
      html
      |> Floki.parse_fragment!()
      |> Floki.find(".custom-question-yes-no-label")
      |> Enum.map(&String.trim(Floki.text(&1)))
    end

    test "keep the shared wording without a theme, and for a theme that does not word them" do
      for theme_key <- [nil, :quill] do
        assert render_in(@note, theme_key) =~ "I acknowledge the above"
        assert prompt_option(render_in(@select, theme_key)) == "Select…"
        assert yes_no_labels(render_in(@yes_no, theme_key)) == ["Yes", "No"]
      end
    end

    test "are worded in the voice of the theme passed" do
      note = render_in(@note, :paper)
      assert note =~ "I have read this"
      refute note =~ "I acknowledge the above"

      assert prompt_option(render_in(@select, :paper)) == "Select an option"
      # Paper keeps Yes and No: they read the same in its words.
      assert yes_no_labels(render_in(@yes_no, :paper)) == ["Yes", "No"]
    end
  end
end
