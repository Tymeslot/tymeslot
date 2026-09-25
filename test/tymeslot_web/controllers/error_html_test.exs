defmodule TymeslotWeb.ErrorHTMLTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :i18n

  import Phoenix.Template, only: [render_to_string: 4]

  test "the 404 page declares the locale it is rendered in" do
    html =
      Gettext.with_locale(TymeslotWeb.Gettext, "de", fn ->
        render_to_string(TymeslotWeb.ErrorHTML, "404", "html", [])
      end)

    assert html =~ ~s(<html lang="de">)
  end
end
