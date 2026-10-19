defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceBookableTest do
  @moduledoc """
  The bookable layer the surface pushes to the hook (`calendar:bookable`):
  the chosen meeting type's windows for the loaded range, the next bookable
  time, a failed load, and every trigger that reloads it.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Mox
  import Tymeslot.Factory
  import TymeslotWeb.BookableLayerHelpers
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.Availability
  alias Tymeslot.CalendarMock
  alias Tymeslot.Integrations.Calendar.CalendarPreferencesQueries

  setup %{conn: conn} do
    context = owner(conn)
    Map.merge(context, open_days(context.user))
  end

  test "with no meeting type the layer has nothing to show and nothing is computed", %{
    conn: conn
  } do
    test_pid = self()

    stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _from, _to ->
      send(test_pid, :fetched)
      {:ok, []}
    end)

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    layer = await_bookable(lv, &(&1.meeting_type == nil))
    assert %{on: true, windows: [], next: nil, error: false} = layer
    refute_received :fetched
  end

  describe "with a meeting type" do
    setup %{user: user} do
      %{intro: meeting_type(user)}
    end

    test "pushes the meeting type's windows for the loaded range", %{conn: conn, intro: intro} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      layer = await_bookable(lv, &on_day?(&1, "2026-10-15"))

      assert layer.on
      assert layer.meeting_type == %{id: intro.id, name: "Intro call"}
      assert layer.timezone == "Europe/London"
      assert layer.error == false
      assert %{start: "2026-10-15T09:00", end: "2026-10-15T17:00"} in layer.windows
      assert %{start: "2026-10-23T09:00", end: "2026-10-23T17:00"} in layer.windows
      # Wednesday is closed, and nothing before today is offered.
      refute on_day?(layer, "2026-10-14")
      refute on_day?(layer, "2026-10-21")
      refute on_day?(layer, "2026-10-12")
      refute on_day?(layer, "2026-10-17")
    end

    test "names the first bookable time from now", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      layer = await_bookable(lv, &on_day?(&1, "2026-10-15"))

      assert layer.next == %{at: "2026-10-15T09:00", label: "Thu 15 Oct, 09:00"}
    end

    test "looks past the loaded range when nothing in it is bookable", %{
      conn: conn,
      profile: profile
    } do
      insert(:time_off_period,
        profile: profile,
        starts_on: ~D[2026-10-14],
        ends_on: ~D[2026-10-25]
      )

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      layer = await_bookable(lv, &(&1.next != nil))

      assert layer.windows == []
      assert layer.next == %{at: "2026-10-26T09:00", label: "Mon 26 Oct, 09:00"}
    end

    test "a load that fails says so and draws nothing", %{conn: conn} do
      stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _from, _to ->
        {:error, :unreachable}
      end)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      layer = await_bookable(lv, & &1.error)
      assert %{on: true, windows: [], next: nil} = layer
    end

    test "with the layer off nothing is computed", %{conn: conn, user: user} do
      {:ok, _preferences} = CalendarPreferencesQueries.upsert(user.id, %{bookable_layer: false})
      test_pid = self()

      stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _from, _to ->
        send(test_pid, :fetched)
        {:ok, []}
      end)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      layer = await_bookable(lv, &(&1.on == false))
      assert %{windows: [], next: nil, meeting_type: %{name: "Intro call"}} = layer
      refute_received :fetched
    end

    test "shows the meeting type the organiser chose", %{conn: conn, user: user} do
      workshop = meeting_type(user, name: "Workshop", duration_minutes: 120, sort_order: 1)

      {:ok, _preferences} =
        CalendarPreferencesQueries.upsert(user.id, %{bookable_meeting_type_id: workshop.id})

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      layer = await_bookable(lv, &on_day?(&1, "2026-10-15"))
      assert layer.meeting_type == %{id: workshop.id, name: "Workshop"}
    end

    test "follows the organiser to another window", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      await_bookable(lv, &on_day?(&1, "2026-10-15"))

      render_patch(lv, "/dashboard/calendar?view=week&date=2026-11-05")

      layer = await_bookable(lv, &on_day?(&1, "2026-11-05"))
      # After the clocks went back, still 09:00 on the organiser's clock.
      assert %{start: "2026-11-05T09:00", end: "2026-11-05T17:00"} in layer.windows
      # The range no longer starts today, so the next time is looked up from now.
      assert layer.next == %{at: "2026-10-15T09:00", label: "Thu 15 Oct, 09:00"}
    end

    test "redraws when the organiser's availability changes", %{
      conn: conn,
      user: user,
      profile: profile
    } do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      await_bookable(lv, &on_day?(&1, "2026-10-15"))

      insert(:time_off_period,
        profile: profile,
        starts_on: ~D[2026-10-15],
        ends_on: ~D[2026-10-15]
      )

      Availability.changed(user.id)

      layer = await_bookable(lv, &(on_day?(&1, "2026-10-16") and not on_day?(&1, "2026-10-15")))
      refute on_day?(layer, "2026-10-15")
    end

    # With the layer off every reload pushes at once (and computes nothing),
    # so the pushes count the reloads exactly; with it on, a load asked for
    # while another runs is folded into it, which hides whether it ran.
    test "changes in quick succession reload the layer once", %{conn: conn, user: user} do
      {:ok, _preferences} = CalendarPreferencesQueries.upsert(user.id, %{bookable_layer: false})
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      await_bookable(lv, &(&1.on == false))

      Availability.changed(user.id)
      Availability.changed(user.id)

      assert_push_event(lv, "calendar:bookable", %{on: false}, 1_000)
      refute_push_event(lv, "calendar:bookable", _payload, 500)
    end

    test "switching the layer off clears it, and on loads it again", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      await_bookable(lv, &on_day?(&1, "2026-10-15"))

      lv |> element("#calendar-rail-bookable") |> render_click()
      assert %{windows: []} = await_bookable(lv, &(&1.on == false))

      lv |> element("#calendar-rail-bookable") |> render_click()
      assert await_bookable(lv, &(&1.on and on_day?(&1, "2026-10-15")))
    end

    test "choosing another meeting type reloads the layer for it", %{conn: conn, user: user} do
      workshop = meeting_type(user, name: "Workshop", duration_minutes: 120, sort_order: 1)
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      await_bookable(lv, &on_day?(&1, "2026-10-15"))

      lv
      |> form("#calendar-rail-bookable-form")
      |> render_change(%{"id" => to_string(workshop.id)})

      layer = await_bookable(lv, &(&1.meeting_type == %{id: workshop.id, name: "Workshop"}))
      assert on_day?(layer, "2026-10-15")
    end

    test "a change while a load runs waits for it, then loads once for the latest choice", %{
      conn: conn,
      user: user
    } do
      workshop = meeting_type(user, name: "Workshop", duration_minutes: 120, sort_order: 1)
      test_pid = self()
      calls = :counters.new(1, [])

      # The first fetch holds the first load in flight until the test says go.
      stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _from, _to ->
        :counters.add(calls, 1, 1)
        send(test_pid, {:fetching, self()})
        if :counters.get(calls, 1) == 1, do: receive(do: (:go -> :ok))
        {:ok, []}
      end)

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      assert_receive {:fetching, first}, 1_000

      lv
      |> form("#calendar-rail-bookable-form")
      |> render_change(%{"id" => to_string(workshop.id)})

      refute_receive {:fetching, _task}, 200
      send(first, :go)

      # The first load's answer is never pushed: the next push is the fresh
      # load for the workshop, and nothing follows it.
      assert_push_event(lv, "calendar:bookable", layer, 1_000)
      assert %{meeting_type: %{name: "Workshop"}, error: false} = layer
      assert on_day?(layer, "2026-10-15")
      refute_push_event(lv, "calendar:bookable", _payload, 300)
    end

    test "the hook's calendar:ready reply carries the layer", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      await_bookable(lv, &on_day?(&1, "2026-10-15"))

      lv |> element("#calendar-canvas") |> render_hook("calendar:ready", %{})

      assert_reply(lv, %{bookable: %{on: true, meeting_type: %{name: "Intro call"}}})
    end
  end
end
