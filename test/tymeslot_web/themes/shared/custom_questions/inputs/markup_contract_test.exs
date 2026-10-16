defmodule TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.MarkupContractTest do
  @moduledoc """
  The markup contract on the custom-question inputs
  (`docs/THEME_DEVELOPMENT_GUIDE.md`, §"The markup contract"), rendered
  through `Inputs.Renderer` as every theme renders them. A question typed
  into is a `<form>` marked with its question id; a question answered by a
  click marks each choice with its id and the value it sends.
  """
  use ExUnit.Case, async: true

  @moduletag :custom_fields
  @moduletag :themes

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.Renderer

  defp render_question(definition, value \\ nil) do
    (&Renderer.render/1)
    |> render_component(%{definition: definition, value: value, myself: nil})
    |> Floki.parse_fragment!()
  end

  defp options(count), do: for(i <- 1..count, do: %{"key" => "opt#{i}", "label" => "Option #{i}"})

  for type <- ~w(short_text number phone url date time) do
    test "a #{type} question marks its form with the question id" do
      id = "q-#{unquote(type)}"
      doc = render_question(%{"id" => id, "type" => unquote(type), "label" => "Question"})

      assert [form] = Floki.find(doc, "form[data-fact='answer']")
      assert Floki.attribute(form, "data-question") == [id]
      assert [_input] = Floki.find(form, "input[name='value']")
    end
  end

  test "a long single select marks its form" do
    doc =
      render_question(%{
        "id" => "q-long",
        "type" => "single_select",
        "label" => "Pick one",
        "options" => options(6)
      })

    assert [form] = Floki.find(doc, "form[data-fact='answer'][data-question='q-long']")
    assert [_select] = Floki.find(form, "select[name='value']")
  end

  test "a short single select marks each choice with the key it sends" do
    doc =
      render_question(%{
        "id" => "q-short",
        "type" => "single_select",
        "label" => "Pick one",
        "options" => options(3)
      })

    choices = "input[data-fact='answer'][data-question='q-short']"

    assert Floki.attribute(doc, choices, "data-value") == ["opt1", "opt2", "opt3"]
    assert Floki.attribute(doc, choices, "phx-value-value") == ["opt1", "opt2", "opt3"]
  end

  test "a multi select marks each choice with the key it sends" do
    doc =
      render_question(%{
        "id" => "q-many",
        "type" => "multi_select",
        "label" => "Pick some",
        "options" => options(3)
      })

    assert Floki.attribute(doc, "input[data-fact='answer'][data-question='q-many']", "data-value") ==
             ["opt1", "opt2", "opt3"]
  end

  test "a yes/no question marks both answers" do
    doc = render_question(%{"id" => "q-yes", "type" => "yes_no", "label" => "Coming?"})

    choices = "input[data-fact='answer'][data-question='q-yes']"

    assert Floki.attribute(doc, choices, "data-value") == ["true", "false"]
    assert Floki.attribute(doc, choices, "phx-value-value") == ["true", "false"]
  end

  test "a note marks its acknowledgement" do
    doc =
      render_question(%{
        "id" => "q-note",
        "type" => "note",
        "label" => "Terms",
        "body" => "Please read this."
      })

    assert Floki.attribute(doc, "input[data-fact='answer'][data-question='q-note']", "data-value") ==
             ["acknowledge"]
  end
end
