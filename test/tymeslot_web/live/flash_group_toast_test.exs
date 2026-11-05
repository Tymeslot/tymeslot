defmodule TymeslotWeb.Live.FlashGroupToastTest do
  @moduledoc """
  Pins two properties of the flash group's toasts on a live page.

  A long unbroken token in a message (a URL, an address) must wrap inside the
  toast instead of running under its close button, which is what the message
  paragraph's `break-words` does. And the slots must run from least to most
  severe: on a phone only the last two visible toasts are shown
  (`assets/css/components/misc.css`), so the order decides which survive.
  """
  use TymeslotWeb.LiveCase, async: true

  @moduletag :ui
  @moduletag :live

  alias Phoenix.Controller

  @long_token "https://example.com/" <> String.duplicate("averylongunbrokenpathsegment", 6)

  setup %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{})
      |> Controller.fetch_flash()
      |> Controller.put_flash(:error, "Could not reach #{@long_token}")
      |> Controller.put_flash(:warning, "Check your calendar")
      |> Controller.put_flash(:info, "Saved")

    {:ok, conn: conn}
  end

  test "a long unbroken token in a message wraps inside the toast", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/auth/reset-password")

    assert has_element?(view, "#app-flash-group-error p.break-words", @long_token)
  end

  test "the toasts run from least to most severe, connection lost last", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/auth/reset-password")

    html = view |> element("#app-flash-group") |> render()

    positions =
      for kind <- ~w(info warning error disconnected) do
        {start, _length} = :binary.match(html, ~s(id="app-flash-group-#{kind}"))
        start
      end

    assert positions == Enum.sort(positions)
  end
end
