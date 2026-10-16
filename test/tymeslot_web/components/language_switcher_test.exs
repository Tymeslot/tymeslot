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
end
