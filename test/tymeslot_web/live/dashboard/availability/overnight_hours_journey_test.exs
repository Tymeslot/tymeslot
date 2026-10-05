defmodule TymeslotWeb.Dashboard.Availability.OvernightHoursJourneyTest do
  @moduledoc """
  An organiser sets Monday's hours to run past midnight on the dashboard and
  adds a break after midnight; the booking page then offers the night's slots
  on both dates.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :availability
  @moduletag :live
  @moduletag :integration

  import Phoenix.LiveViewTest
  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Availability.AvailabilityBreakSchema
  alias Tymeslot.Availability.WeeklySchedule
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  setup :setup_dashboard_user

  setup %{profile: profile} = ctx do
    schedule = insert(:availability_schedule, profile: profile, is_default: true)

    for day_of_week <- 1..7 do
      insert(:weekly_availability,
        schedule: schedule,
        day_of_week: day_of_week,
        is_available: day_of_week == 1,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )
    end

    Map.put(ctx, :schedule, schedule)
  end

  defp select_end_options(view, day) do
    view
    |> render()
    |> Floki.parse_document!()
    |> Floki.find("#day-hours-form-#{day} select[name='end'] option")
    |> Floki.attribute("value")
  end

  test "overnight hours set in the editor are stored and break pickers follow them",
       %{conn: conn, schedule: schedule} do
    {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

    assert "02:00+1" in select_end_options(view, 1)
    refute render(view) =~ "Ends the next day"

    view
    |> form("#day-hours-form-1", %{"day" => "1", "start" => "22:00", "end" => "02:00+1"})
    |> render_change()

    day = WeeklySchedule.get_day_availability(schedule.id, 1)
    assert {day.start_time, day.end_time, day.ends_next_day} == {~T[22:00:00], ~T[02:00:00], true}
    assert render(view) =~ "Ends the next day"

    assert view |> element(~s|#day-hours-form-1 select[name="end"]|) |> render() =~
             ~s|aria-describedby="day-end-hint-1"|

    view
    |> element("button[phx-click='show_add_break_form'][phx-value-day='1']")
    |> render_click()

    picker = view |> element("#add-break-form-1 select[name='start']") |> render()
    assert picker =~ "1:00 AM (+1)"
    assert picker =~ "10:00 PM"
    refute picker =~ ">2:00 AM"

    view
    |> form("form[phx-submit='add_break']", %{
      "day" => "1",
      "start" => "01:00",
      "end" => "01:30",
      "label" => "Tea"
    })
    |> render_submit()

    day = WeeklySchedule.get_day_availability(schedule.id, 1)

    assert [%AvailabilityBreakSchema{start_time: ~T[01:00:00], end_time: ~T[01:30:00]}] =
             Repo.all_by(AvailabilityBreakSchema, weekly_availability_id: day.id)

    # Both of the break's times fall on Tuesday.
    assert render(view) =~ "1:00 AM (+1) - 1:30 AM (+1)"
  end

  test "hours ending at midnight show as a next-day end with no next-day hint",
       %{conn: conn, schedule: schedule} do
    {:ok, _day} =
      WeeklySchedule.upsert_day_availability(schedule.id, 1, %{
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[00:00:00],
        ends_next_day: true
      })

    {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

    assert view
           |> element(~s|#day-hours-form-1 select[name="end"] option[selected]|)
           |> render() =~ "12:00 AM (+1)"

    refute view |> element("#day-hours-form-1") |> render() =~ "24:00"
    refute render(view) =~ "Ends the next day"
  end

  test "changing only the start keeps a next-day end", %{conn: conn, schedule: schedule} do
    {:ok, _day} =
      WeeklySchedule.upsert_day_availability(schedule.id, 1, %{
        is_available: true,
        start_time: ~T[22:00:00],
        end_time: ~T[02:00:00],
        ends_next_day: true
      })

    {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

    # A form change event carrying only the start, as a debounced select change may.
    view
    |> with_target("#availability-list")
    |> render_change("update_day_hours", %{"day" => "1", "start" => "21:00"})

    day = WeeklySchedule.get_day_availability(schedule.id, 1)
    assert {day.start_time, day.end_time, day.ends_next_day} == {~T[21:00:00], ~T[02:00:00], true}
  end

  test "hours over 24 hours show their error under that day's hours and change nothing",
       %{conn: conn, schedule: schedule} do
    {:ok, _day} =
      WeeklySchedule.upsert_day_availability(schedule.id, 1, %{
        is_available: true,
        start_time: ~T[22:00:00],
        end_time: ~T[02:00:00],
        ends_next_day: true
      })

    {:ok, view, _html} = live(conn, ~p"/dashboard/availability")
    refute has_element?(view, "#day-hours-errors-1")

    view
    |> form("#day-hours-form-1", %{"day" => "1", "start" => "01:00", "end" => "02:00+1"})
    |> render_change()

    assert view |> element("#day-hours-errors-1") |> render() =~
             "Hours that end the next day can last at most 24 hours"

    assert has_element?(view, ~s|#day-hours-errors-1[role="alert"]|)

    assert view |> element(~s|#day-hours-form-1 select[name="end"]|) |> render() =~
             ~s|aria-describedby="day-end-hint-1 day-hours-errors-1"|

    day = WeeklySchedule.get_day_availability(schedule.id, 1)
    assert {day.start_time, day.end_time, day.ends_next_day} == {~T[22:00:00], ~T[02:00:00], true}
  end

  test "hours and a break set in the editor decide the night's slots on both dates",
       %{conn: conn, profile: profile} do
    {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

    view
    |> form("#day-hours-form-1", %{"day" => "1", "start" => "22:00", "end" => "02:00+1"})
    |> render_change()

    view
    |> element("button[phx-click='show_add_break_form'][phx-value-day='1']")
    |> render_click()

    view
    |> form("form[phx-submit='add_break']", %{
      "day" => "1",
      "start" => "01:00",
      "end" => "01:30",
      "label" => "Tea"
    })
    |> render_submit()

    monday = next_monday()
    TestMocks.stub_no_calendar_events()

    # Grid 22:00, 23:00, 00:00, 01:00; 01:00 overlaps the break, which sits on
    # Tuesday, so Tuesday keeps only 12:00 AM (ending as the break starts).
    assert offered(profile, monday, 60) == ["10:00 PM", "11:00 PM"]
    assert offered(profile, Date.add(monday, 1), 60) == ["12:00 AM"]
  end

  defp next_monday do
    today = Date.add(Date.utc_today(), 10)
    Date.add(today, Integer.mod(1 - Date.day_of_week(today), 7))
  end
end
