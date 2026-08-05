defmodule TymeslotWeb.Dashboard.ProfileSettingsTimeFormatTest do
  @moduledoc """
  Covers the Time Format section of Profile Settings: the control an organiser
  actually uses to pick a 12- or 24-hour clock, and the fact that it writes to
  the same stored preference the calendar's own settings modal reads.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :profiles
  @moduletag :live

  import Tymeslot.DashboardTestHelpers

  alias Tymeslot.CalendarGrid

  setup :setup_dashboard_user

  describe "the Time Format section" do
    test "is offered on the settings page with both clocks", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/settings")

      assert html =~ "Time Format"
      assert html =~ "12h (AM/PM)"
      assert html =~ "24h"
    end

    test "stores the organiser's choice", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/settings")

      view
      |> element("#profile-time-format-toggle-24h")
      |> render_click()

      assert CalendarGrid.get_user_time_format(user.id, "en") == "24h"
    end

    test "confirms the change to the organiser", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/settings")

      view |> element("#profile-time-format-toggle-24h") |> render_click()

      # The flash is raised by the component but rendered by the parent
      # LiveView, so it only appears once the parent has re-rendered.
      assert render(view) =~ "Time format updated"
    end

    test "the choice survives a reload and stays selected", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/settings")

      view |> element("#profile-time-format-toggle-24h") |> render_click()

      {:ok, _reloaded, html} = live(conn, ~p"/dashboard/settings")

      # The active option carries the primary button styling; the inactive one
      # does not. Asserting on the rendered state rather than the stored value
      # is what proves the form reads back what it wrote.
      assert html =~ ~r/id="profile-time-format-toggle-24h"[^>]*class="[^"]*btn-primary/s
    end

    test "writes to the same preference the calendar settings modal uses", %{
      conn: conn,
      user: user
    } do
      # One store, two controls: picking 24h here must be what the calendar
      # grid reads, otherwise the dashboard disagrees with itself.
      {:ok, view, _html} = live(conn, ~p"/dashboard/settings")

      view |> element("#profile-time-format-toggle-24h") |> render_click()

      assert CalendarGrid.get_or_create_preferences(user.id).time_format == "24h"
    end

    test "can be switched back to a 12-hour clock", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/settings")

      view |> element("#profile-time-format-toggle-24h") |> render_click()
      view |> element("#profile-time-format-toggle-12h") |> render_click()

      assert CalendarGrid.get_user_time_format(user.id, "de") == "12h"
    end
  end
end
