defmodule TymeslotWeb.Themes.Shared.Components.CustomAnswersTest do
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :custom_fields
  @moduletag :components

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias TymeslotWeb.Themes.Shared.Components.CustomAnswers

  @snapshot [
    %{"id" => "q1", "label" => "Company", "type" => "short_text"},
    %{"id" => "q2", "label" => "Newsletter?", "type" => "yes_no"}
  ]

  defp render_answers(assigns) do
    html = render_component(&CustomAnswers.custom_answers/1, assigns)
    Floki.parse_fragment!(html)
  end

  defp column(doc, selector) do
    doc
    |> Floki.find(".custom-answers__row")
    |> Enum.map(&(&1 |> Floki.find(selector) |> Floki.text() |> String.trim()))
  end

  test "lists every question with the guest's answer, in the snapshot's order" do
    doc = render_answers(%{snapshot: @snapshot, answers: %{"q1" => "Acme", "q2" => true}})

    assert doc |> Floki.find("section.custom-answers h3.custom-answers__heading") |> Floki.text() =~
             "Your answers"

    assert column(doc, "dt.custom-answers__label") == ["Company", "Newsletter?"]
    assert column(doc, "dd.custom-answers__value") == ["Acme", "Yes"]
  end

  test "tolerates answers not yet assigned, skipping the empty ones" do
    doc = render_answers(%{snapshot: @snapshot, answers: nil})

    assert column(doc, "dt.custom-answers__label") == ["Newsletter?"]
    assert column(doc, "dd.custom-answers__value") == ["No"]
  end

  @note %{"id" => "q3", "label" => "I have read the terms", "type" => "note"}

  test "gives an unticked note no row" do
    doc = render_answers(%{snapshot: @snapshot ++ [@note], answers: %{"q1" => "Acme"}})

    assert column(doc, "dt.custom-answers__label") == ["Company", "Newsletter?"]
  end

  test "lists a ticked note" do
    answers = %{"q3" => %{"confirmed" => true, "confirmed_at" => "2026-10-01"}}
    doc = render_answers(%{snapshot: [@note], answers: answers})

    assert column(doc, "dt.custom-answers__label") == ["I have read the terms"]
  end

  test "renders nothing when every answer is empty" do
    assert Floki.find(render_answers(%{snapshot: [@note], answers: %{}}), ".custom-answers") == []
  end

  test "renders nothing for a meeting type without questions" do
    assert Floki.find(render_answers(%{snapshot: [], answers: %{}}), ".custom-answers") == []
    assert Floki.find(render_answers(%{snapshot: nil, answers: %{}}), ".custom-answers") == []
  end
end
