defmodule TymeslotWeb.Themes.Core.DispatcherErrorCardTest do
  @moduledoc """
  The dispatcher's last-resort error card, shown when a theme cannot be loaded
  or raises inside a callback, is part of the visitor's booking page and so
  speaks the visitor's language, like the rest of the page.
  """

  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :i18n
  @moduletag :unit

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias TymeslotWeb.Themes.Core.Dispatcher

  defp render_card(assigns) do
    %{__changed__: nil}
    |> Map.merge(assigns)
    |> Dispatcher.render()
    |> rendered_to_string()
    |> Floki.parse_fragment!()
  end

  defp text(document, selector),
    do: document |> Floki.find(selector) |> Floki.text() |> String.trim()

  describe "a theme that cannot be loaded" do
    # An unknown `?theme=` or stored theme id falls back to the organiser's or
    # the default theme (see `ThemeHookTest`), so a live page cannot reach this
    # card through its address. An id that resolves to no theme at render time
    # stands in for it.
    @tag :capture_log
    test "shows the error card in German on a German booking page" do
      document = render_card(%{theme_id: "999", live_action: :cancel, locale: "de"})

      assert text(document, "h1") == "Etwas ist schiefgelaufen"

      assert Floki.text(document) =~
               "Diese Seite konnte nicht geladen werden. Bitte versuchen Sie es erneut."

      assert text(document, "#theme-error-retry-button") == "Erneut versuchen"
    end

    @tag :capture_log
    test "shows the error card in English by default" do
      document = render_card(%{theme_id: "999", live_action: :cancel, locale: "en"})

      assert text(document, "h1") == "Something went wrong"
      assert text(document, "#theme-error-retry-button") == "Try again"
    end
  end

  describe "a theme that raises inside a callback" do
    # `ErrorBoundary` records the failure as `:theme_error`; its own tests cover
    # the catching, and this pins what the dispatcher then renders for it. The
    # message names what failed, and is translated at render time when the
    # boundary left none.
    test "renders the translated error card for the recorded failure" do
      document =
        render_card(%{theme_error: %{function: :handle_event, theme_id: "1"}, locale: "de"})

      assert text(document, "h1") == "Etwas ist schiefgelaufen"

      assert Floki.text(document) =~
               "Ihre letzte Aktion konnte nicht abgeschlossen werden. Bitte versuchen Sie es erneut."

      assert text(document, "#theme-error-retry-button") == "Erneut versuchen"
    end
  end
end
