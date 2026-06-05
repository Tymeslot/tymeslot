defmodule TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.UrlTest do
  use ExUnit.Case, async: true

  @moduletag :custom_fields

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Themes.Shared.CustomQuestions.Inputs.Url

  defp render_input(definition, value \\ nil) do
    render_component(&Url.render/1, definition: definition, value: value, myself: nil)
  end

  test "renders an HTML5 url input" do
    html = render_input(%{"type" => "url", "label" => "Website"})
    assert html =~ ~s(type="url")
    assert html =~ ~s(phx-change="answer")
  end

  test "renders the provided value" do
    html = render_input(%{"type" => "url", "label" => "Website"}, "https://example.com")
    assert html =~ "https://example.com"
  end
end
