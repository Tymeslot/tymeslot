defmodule TymeslotWeb.Dashboard.ThemeSettingsFlashTest do
  @moduledoc """
  Regression test for Task 95 — flash messages emitted by
  `ThemeSettingsComponent` must reach the parent `DashboardLive`.

  `put_flash/3` called on a `Phoenix.LiveComponent` socket is silently
  dropped, so the component forwards flashes via
  `TymeslotWeb.Live.Shared.Flash.put_flash/3`, which the dashboard picks
  up in `handle_info({:flash, _}, _)`. This test drives one of the error
  paths that used to go missing and asserts the flash renders.
  """

  use TymeslotWeb.LiveCase, async: true
  @moduletag :utils

  import Tymeslot.DashboardTestHelpers

  setup :setup_dashboard_user_with_theme

  test "flashes an error when the theme component rejects an unknown id", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dashboard/theme")

    # Click an existing theme button but override the value with an id that
    # fails `Theme.valid_theme_id?/1`, so the component falls into the
    # "Invalid theme selection" branch that previously called `put_flash`
    # on the component socket and was silently dropped.
    view
    |> element("[phx-click='select_theme'][phx-value-theme='1']")
    |> render_click(%{"theme" => "not-a-real-theme"})

    # The flash is delivered to the parent via `send(self(), {:flash, _})`
    # from the component, which is processed in a separate `handle_info`
    # cycle. Drain the mailbox synchronously so the assertion is stable.
    _drain = :sys.get_state(view.pid)

    assert render(view) =~ "Invalid theme selection"
  end
end
