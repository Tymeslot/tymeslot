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
    assert html =~ ~r/<option[^>]*selected[^>]*value="k3"|<option[^>]*value="k3"[^>]*selected/
    refute html =~ ~s(type="radio")
  end

  test "the select fallback sits in a form that commits the answer" do
    d = %{"id" => "q9", "type" => "single_select", "label" => "Pick", "options" => options(6)}
    doc = d |> render_input() |> Floki.parse_fragment!()

    # LiveView's client only sends phx-change from an input inside a form; a bare
    # select throws in the browser and the answer never reaches the server.
    assert [_select] =
             Floki.find(
               doc,
               "form#cq-form-q9[phx-change='answer'][phx-submit='next_step'] select[name='value']"
             )

    assert Floki.find(doc, "select[phx-change]") == []
  end

  test "the select fallback includes an empty placeholder option" do
    d = %{"type" => "single_select", "label" => "Pick", "options" => options(6)}
    html = render_input(d)

    assert html =~ ~s(<option value="">)
  end

  test "the select fallback sits in the wrapper that draws its chevron, with nothing else" do
    d = %{"id" => "q9", "type" => "single_select", "label" => "Pick", "options" => options(6)}
    doc = d |> render_input() |> Floki.parse_fragment!()

    # The chevron is centred on the wrapper, so the wrapper must hold the
    # select alone: a label or an error inside it would pull the chevron off
    # the select's middle.
    assert [wrapper] = Floki.find(doc, "form#cq-form-q9 .custom-question-select")
    assert [_select] = Floki.find(wrapper, "select[name='value']")
    assert Floki.find(wrapper, "label, .form-field-error, p") == []
  end
end
