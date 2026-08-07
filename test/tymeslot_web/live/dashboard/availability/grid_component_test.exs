defmodule TymeslotWeb.Live.Dashboard.Availability.GridComponentTest do
  @moduledoc """
  Coverage for the Grid half of the availability editor.

  `ScheduleSettingsComponent` offers the organiser two views of the same
  weekly schedule, List and Grid, behind a `toggle_input_mode` button pair.
  Everything written so far tests the List side: `availability_live_test.exs`
  drives toggling days, editing hours, adding and deleting breaks, and
  `ListComponentCompositionTest` covers its validation seam. Nothing rendered
  the Grid at all — no test in the suite referenced `GridComponent`, so its
  template was never compiled against real data.

  That matters more than it sounds. The Grid is a *derived* view: it turns
  each day's start/end times into positioned bars via `mobile_row_data/2` and
  the slot arithmetic around `@grid_start_minutes`. A schedule the List view
  renders correctly can still place a bar in the wrong column, or crash on a
  day the organiser has switched off, and nothing would have said so.

  These tests therefore assert on what the grid *shows* for a known schedule,
  not merely that the component renders.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :availability
  @moduletag :live
  @moduletag :integration

  import Phoenix.LiveViewTest
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.CalendarGrid

  setup :setup_dashboard_user

  defp switch_to_grid(conn) do
    {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

    view
    |> element("button[phx-click='toggle_input_mode'][phx-value-option='grid']")
    |> render_click()

    view
  end

  describe "switching to the grid view" do
    setup %{profile: profile} do
      Enum.each(1..7, fn day_of_week ->
        insert(:weekly_availability,
          profile: profile,
          day_of_week: day_of_week,
          is_available: day_of_week <= 5,
          start_time: ~T[09:00:00],
          end_time: ~T[17:00:00]
        )
      end)

      :ok
    end

    test "renders the grid and every day of the week", %{conn: conn} do
      html = conn |> switch_to_grid() |> render()

      assert html =~ "Weekly Visual Grid"

      for day <- ~w(Monday Tuesday Wednesday Thursday Friday Saturday Sunday) do
        assert html =~ day, "expected the grid to label #{day}"
      end
    end

    test "the toggle is reversible — switching back restores the list editor", %{conn: conn} do
      view = switch_to_grid(conn)

      assert render(view) =~ "Weekly Visual Grid"

      view
      |> element("button[phx-click='toggle_input_mode'][phx-value-option='list']")
      |> render_click()

      refute render(view) =~ "Weekly Visual Grid"
    end

    test "shows the organiser's configured hours", %{conn: conn} do
      html = conn |> switch_to_grid() |> render()

      # 09:00–17:00 in the profile's 12-hour default rendering.
      assert html =~ "9:00 AM"
      assert html =~ "5:00 PM"
    end
  end

  describe "days the organiser is unavailable" do
    setup %{profile: profile} do
      # Monday on, everything else off — the shape that exercises both the
      # "has a bar" and "has no bar" branches of the row builder in one render.
      Enum.each(1..7, fn day_of_week ->
        insert(:weekly_availability,
          profile: profile,
          day_of_week: day_of_week,
          is_available: day_of_week == 1,
          start_time: ~T[10:00:00],
          end_time: ~T[12:00:00]
        )
      end)

      :ok
    end

    test "renders without raising when most days are switched off", %{conn: conn} do
      html = conn |> switch_to_grid() |> render()

      assert html =~ "Weekly Visual Grid"
      assert html =~ "10:00 AM"
      assert html =~ "12:00 PM"
    end
  end

  describe "a profile with no weekly schedule rows" do
    test "renders the empty grid rather than crashing", %{conn: conn} do
      # A profile mid-onboarding has no `weekly_availability` rows at all.
      # `update/2` defaults `weekly_schedule` to `[]`; this pins that the
      # template survives an empty `day_map`.
      html = conn |> switch_to_grid() |> render()

      assert html =~ "Weekly Visual Grid"
      assert html =~ "Monday"
    end
  end

  describe "24-hour time format" do
    setup %{user: user, profile: profile} do
      Enum.each(1..7, fn day_of_week ->
        insert(:weekly_availability,
          profile: profile,
          day_of_week: day_of_week,
          is_available: true,
          start_time: ~T[09:00:00],
          end_time: ~T[17:00:00]
        )
      end)

      %{user: user}
    end

    test "respects the organiser's 24-hour preference", %{conn: conn, user: user} do
      {:ok, _preferences} = CalendarGrid.save_preferences(user.id, %{time_format: "24h"})

      html = conn |> switch_to_grid() |> render()

      assert html =~ "17:00"
      refute html =~ "5:00 PM"
    end
  end
end
