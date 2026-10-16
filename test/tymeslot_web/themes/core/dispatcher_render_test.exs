defmodule TymeslotWeb.Themes.Core.DispatcherRenderTest do
  @moduledoc """
  The dispatcher's fallback when no theme can draw the page: an id that
  resolves to no theme shows the error card, in the visitor's language,
  and is logged.
  """

  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias TymeslotWeb.Themes.Core.Dispatcher

  defp render(assigns) do
    %{__changed__: nil}
    |> Map.merge(assigns)
    |> Dispatcher.render()
    |> rendered_to_string()
  end

  test "an id that resolves to no theme shows the error card" do
    html = render(%{theme_id: "9", live_action: :cancel})

    assert html =~ "Something went wrong"
    assert html =~ "This page could not be loaded. Please try again."
    assert html =~ "Try again"
  end

  test "an id that resolves to no theme is logged, naming the id" do
    log = capture_log(fn -> render(%{theme_id: "9", live_action: :cancel}) end)

    assert log =~ "Theme module not found"
  end

  test "the error card is translated into the page's locale" do
    html = render(%{theme_id: "9", live_action: :cancel, locale: "de"})

    assert html =~ "Etwas ist schiefgelaufen"
    assert html =~ "Diese Seite konnte nicht geladen werden. Bitte versuchen Sie es erneut."
    assert html =~ "Erneut versuchen"
    refute html =~ "Something went wrong"
  end
end
