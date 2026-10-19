defmodule TymeslotWeb.Dashboard.CalendarGrid.VisibleWindowLiveViewTest do
  @moduledoc """
  The grid shows every event on the days it displays, as the viewer's zone
  reads them, and nothing from the days either side: a host west of UTC sees
  their late evening on the last visible day, a host east of UTC sees their
  early morning on the first.

  Each test freezes the clock the grid reads, so the visible period is fixed
  rather than whichever week the suite happens to run in.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory
  import Tymeslot.Test.ClockHelpers

  alias Plug.Test
  alias Tymeslot.CalendarGrid

  # A Sunday that ends a month: the week shown is Monday 22 to Sunday 28
  # February, and the agenda runs from the 28th to 30 March.
  @sunday ~D[2027-02-28]

  defp sign_in(conn, timezone) do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    insert(:profile, user: user, timezone: timezone)
    integration = insert(:calendar_integration, user: user, is_active: true)
    conn = conn |> Test.init_test_session(%{}) |> fetch_session() |> log_in_user(user)
    {conn, integration}
  end

  defp freeze_at(date, time, timezone), do: freeze_clock(local(date, time, timezone))

  defp local(date, time, timezone),
    do: date |> DateTime.new!(time, timezone) |> DateTime.shift_zone!("Etc/UTC")

  defp insert_event(integration, date, time, timezone) do
    start_at = local(date, time, timezone)

    insert(:provider_calendar_event,
      calendar_integration: integration,
      summary: "Late call",
      start_at: start_at,
      end_at: DateTime.add(start_at, 30, :minute),
      all_day: false,
      recurrence_rule: nil,
      recurring_event_id: nil,
      sync_state: "synced"
    )
  end

  defp on_grid?(lv, event), do: has_element?(lv, "[id^='event-#{event.id}-']")

  defp grid_hook(lv, event, params \\ %{}),
    do: lv |> element("#calendar-grid") |> render_hook(event, params)

  describe "a frozen clock" do
    test "is the one the mounted grid opens on", %{conn: conn} do
      {conn, _integration} = sign_in(conn, "America/New_York")
      freeze_at(@sunday, ~T[17:00:00], "America/New_York")

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      assert has_element?(lv, "[data-day-col='2027-02-22']")
      assert has_element?(lv, "#current-time-2027-02-28")
    end
  end

  describe "a host west of UTC" do
    setup %{conn: conn} do
      {conn, integration} = sign_in(conn, "America/New_York")
      freeze_at(@sunday, ~T[17:00:00], "America/New_York")
      {:ok, conn: conn, integration: integration}
    end

    test "sees an evening event on the last day of the week", %{conn: conn, integration: i} do
      # 22:00 in New York is 03:00 UTC on 1 March, after the week's last UTC day.
      event = insert_event(i, @sunday, ~T[22:00:00], "America/New_York")

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      assert on_grid?(lv, event)
    end

    test "does not see the days either side of the week", %{conn: conn, integration: i} do
      after_week = insert_event(i, ~D[2027-03-01], ~T[00:30:00], "America/New_York")
      before_week = insert_event(i, ~D[2027-02-21], ~T[23:30:00], "America/New_York")

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      assert has_element?(lv, "[data-day-col='2027-02-28']")
      refute on_grid?(lv, after_week)
      refute on_grid?(lv, before_week)
    end

    test "sees an evening event on the agenda's last day, and not the day after", %{
      conn: conn,
      integration: i
    } do
      last_day = Date.add(@sunday, 30)
      on_last_day = insert_event(i, last_day, ~T[22:00:00], "America/New_York")
      day_after = insert_event(i, Date.add(last_day, 1), ~T[00:30:00], "America/New_York")

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> element("#calendar-grid") |> render_hook("set_view", %{"view" => "agenda"})

      assert has_element?(lv, "#agenda-event-#{on_last_day.id}-#{Date.to_iso8601(last_day)}")
      refute has_element?(lv, "[id^='agenda-event-#{day_after.id}-']")
    end
  end

  describe "a host east of UTC" do
    setup %{conn: conn} do
      {conn, integration} = sign_in(conn, "Asia/Tokyo")
      freeze_at(~D[2027-02-24], ~T[12:00:00], "Asia/Tokyo")
      {:ok, conn: conn, integration: integration}
    end

    test "sees an early event on the first day of the week, and not the night before", %{
      conn: conn,
      integration: i
    } do
      # 00:30 on Monday in Tokyo is 15:30 UTC on the Sunday before.
      first_morning = insert_event(i, ~D[2027-02-22], ~T[00:30:00], "Asia/Tokyo")
      night_before = insert_event(i, ~D[2027-02-21], ~T[23:30:00], "Asia/Tokyo")

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      assert on_grid?(lv, first_morning)
      refute on_grid?(lv, night_before)
    end
  end

  # Santiago's clocks skip from 00:00 to 01:00 on Sunday 6 September 2026.
  describe "a host whose clocks skip a midnight" do
    setup %{conn: conn} do
      {conn, integration} = sign_in(conn, "America/Santiago")
      freeze_at(~D[2026-09-06], ~T[12:00:00], "America/Santiago")
      {:ok, conn: conn, integration: integration}
    end

    test "sees that day's events in the week and the day", %{conn: conn, integration: i} do
      event = insert_event(i, ~D[2026-09-06], ~T[09:00:00], "America/Santiago")

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      assert on_grid?(lv, event)

      grid_hook(lv, "set_view", %{"view" => "day"})
      assert on_grid?(lv, event)
    end

    test "sees that day's events in the agenda", %{conn: conn, integration: i} do
      event = insert_event(i, ~D[2026-09-06], ~T[09:00:00], "America/Santiago")

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      grid_hook(lv, "set_view", %{"view" => "agenda"})

      assert has_element?(lv, "#agenda-event-#{event.id}-2026-09-06")
    end
  end

  # The grid loads only the days it shows, so a preference that changes which
  # days those are has to load the new ones.
  describe "a preference that changes the days shown" do
    setup %{conn: conn} do
      {conn, integration} = sign_in(conn, "America/New_York")
      # Wednesday 24 February 2027: the Monday week is 22-28 February.
      freeze_at(~D[2027-02-24], ~T[12:00:00], "America/New_York")
      {:ok, conn: conn, integration: integration}
    end

    test "turning weekends on shows the weekend's events", %{conn: conn, integration: i} do
      user_id = i.user_id
      {:ok, _prefs} = CalendarGrid.save_preferences(user_id, %{show_weekends: false})
      saturday = insert_event(i, ~D[2027-02-27], ~T[14:00:00], "America/New_York")

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      refute on_grid?(lv, saturday)

      grid_hook(lv, "toggle_weekends")

      assert on_grid?(lv, saturday)
    end

    test "starting the week on Sunday shows that Sunday's events", %{conn: conn, integration: i} do
      sunday = insert_event(i, ~D[2027-02-21], ~T[14:00:00], "America/New_York")

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      refute on_grid?(lv, sunday)

      grid_hook(lv, "update_week_start", %{"option" => "sunday"})

      assert has_element?(lv, "[data-day-col='2027-02-21']")
      assert on_grid?(lv, sunday)
    end

    test "starting the week on Sunday shows the month's new first cell", %{
      conn: conn,
      integration: i
    } do
      # February 2027 starts on a Monday, so a Sunday start adds 31 January.
      cell = insert_event(i, ~D[2027-01-31], ~T[14:00:00], "America/New_York")

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      grid_hook(lv, "set_view", %{"view" => "month"})
      refute on_grid?(lv, cell)

      grid_hook(lv, "update_week_start", %{"option" => "sunday"})

      assert on_grid?(lv, cell)
    end
  end

  test "an event with no length at the first day's midnight is shown", %{conn: conn} do
    {conn, integration} = sign_in(conn, "America/New_York")
    freeze_at(@sunday, ~T[17:00:00], "America/New_York")
    start_at = local(~D[2027-02-22], ~T[00:00:00], "America/New_York")

    marker =
      insert(:provider_calendar_event,
        calendar_integration: integration,
        summary: "Marker",
        start_at: start_at,
        end_at: start_at,
        all_day: false,
        recurrence_rule: nil,
        recurring_event_id: nil,
        sync_state: "synced"
      )

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    assert on_grid?(lv, marker)
  end

  test "the agenda lists an event with no length at a day's midnight, on that day", %{
    conn: conn
  } do
    {conn, integration} = sign_in(conn, "America/New_York")
    freeze_at(@sunday, ~T[17:00:00], "America/New_York")
    day = Date.add(@sunday, 2)
    start_at = local(day, ~T[00:00:00], "America/New_York")

    marker =
      insert(:provider_calendar_event,
        calendar_integration: integration,
        summary: "Marker",
        start_at: start_at,
        end_at: start_at,
        all_day: false,
        recurrence_rule: nil,
        recurring_event_id: nil,
        sync_state: "synced"
      )

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    grid_hook(lv, "set_view", %{"view" => "agenda"})

    assert has_element?(lv, "#agenda-event-#{marker.id}-#{Date.to_iso8601(day)}")
    refute has_element?(lv, "#agenda-event-#{marker.id}-#{Date.to_iso8601(Date.add(day, -1))}")
  end

  test "a stored event with no end does not stop the rest of the week showing", %{conn: conn} do
    {conn, integration} = sign_in(conn, "America/New_York")
    freeze_at(@sunday, ~T[17:00:00], "America/New_York")
    whole = insert_event(integration, ~D[2027-02-24], ~T[10:00:00], "America/New_York")

    # Written before the cache's writers checked timing; the factory, like
    # `insert_all`, runs no changeset.
    insert(:provider_calendar_event,
      calendar_integration: integration,
      start_at: local(~D[2027-02-24], ~T[12:00:00], "America/New_York"),
      end_at: nil,
      all_day: false,
      recurrence_rule: nil,
      recurring_event_id: nil,
      sync_state: "synced"
    )

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    assert on_grid?(lv, whole)
  end

  test "searching past a stored event with no end lists the rest", %{conn: conn} do
    {conn, integration} = sign_in(conn, "America/New_York")
    freeze_at(@sunday, ~T[17:00:00], "America/New_York")
    _whole = insert_event(integration, ~D[2027-02-24], ~T[10:00:00], "America/New_York")

    insert(:provider_calendar_event,
      calendar_integration: integration,
      summary: "Late half",
      start_at: local(~D[2027-02-24], ~T[12:00:00], "America/New_York"),
      end_at: nil,
      all_day: false,
      recurrence_rule: nil,
      recurring_event_id: nil,
      sync_state: "synced"
    )

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    lv |> form("#calendar-search-form", %{term: "Late"}) |> render_change()

    results = lv |> element("#calendar-search-results") |> render()
    assert results =~ "Late call"
    refute results =~ "Late half"
  end
end
