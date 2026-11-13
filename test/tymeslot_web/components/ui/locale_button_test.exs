defmodule TymeslotWeb.Components.UI.LocaleButtonTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :components
  @moduletag :i18n

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Components.UI.LocaleButton

  test "names the language in a tooltip as well as to screen readers" do
    html =
      render_component(&LocaleButton.locale_button/1, %{
        locale: %{code: "de", name: "Deutsch", country_code: :deu},
        active: false
      })

    doc = Floki.parse_fragment!(html)

    assert doc |> Floki.find("[data-tooltip] > button") |> Floki.attribute("aria-label") ==
             ["Deutsch"]

    assert doc |> Floki.find("[role='tooltip']") |> Floki.text() =~ "Deutsch"
    assert Floki.find(doc, "button[title]") == []
  end
end
