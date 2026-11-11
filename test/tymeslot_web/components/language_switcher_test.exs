defmodule TymeslotWeb.Components.LanguageSwitcherTest do
  use ExUnit.Case, async: true

  @moduletag :i18n
  @moduletag :components

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Components.LanguageSwitcher

  @locales [%{code: "en", name: "English"}, %{code: "de", name: "Deutsch"}]

  defp render_switcher do
    html =
      render_component(&LanguageSwitcher.language_switcher/1,
        locale: "de",
        locales: @locales,
        dropdown_open: true
      )

    Floki.parse_document!(html)
  end

  test "emits one theme-neutral set of class names" do
    doc = render_switcher()

    assert [_root] = Floki.find(doc, ".lang-switcher")
    assert [_button] = Floki.find(doc, ".lang-switcher__button")
    assert [_panel] = Floki.find(doc, ".lang-switcher__panel")
    assert length(Floki.find(doc, ".lang-switcher__item")) == 2

    html = Floki.raw_html(doc)
    refute html =~ "quill"
    refute html =~ "rhythm"
  end

  test "marks only the current locale active" do
    doc = render_switcher()

    assert [active] = Floki.find(doc, ".lang-switcher__item--active")
    assert Floki.attribute([active], "phx-value-locale") == ["de"]
  end

  test "names the trigger after the language it shows, then what it does" do
    doc = render_switcher()

    # Label in Name (WCAG 2.5.3): the name starts with the visible "Deutsch".
    assert [label] = Floki.attribute(doc, ".lang-switcher__button", "aria-label")
    assert label == "Deutsch, change language"
  end

  test "shows the language name on the trigger at every screen width" do
    doc = render_switcher()

    assert [name] = Floki.find(doc, ".lang-switcher__button span")
    assert Floki.text(name) =~ "Deutsch"
    refute "hidden" in (name |> Floki.attribute("class") |> Enum.flat_map(&String.split/1))
  end
end
