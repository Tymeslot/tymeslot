defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfacePanelTimingTest do
  @moduledoc """
  The side panel's timing: the end follows the start and keeps the event's
  length (across a clock change too), a changed end never moves the start,
  an end before the start is refused in the field, all-day dates are shown
  inclusive and stored exclusive, and All day toggles the event.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.Factory
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.CalendarMock

  setup %{conn: conn} do
    context = owner(conn)
    test_pid = self()

    Mox.stub(CalendarMock, :update_event, fn uid, payload, _context ->
      send(test_pid, {:written, uid, payload})
      :ok
    end)

    # 10:00 to 11:00 in London on Wednesday 14 October.
    review = event(context.integration, "work", "Design review", ~U[2026-10-14 09:00:00Z])
    {:ok, lv, _html} = live(context.conn, ~p"/dashboard/calendar")

    Map.merge(context, %{lv: lv, review: review})
  end

  defp edit(lv, event) do
    lv
    |> element("#calendar-canvas")
    |> render_hook("calendar:edit", %{"id" => "event-#{event.id}"})

    lv
  end

  defp change_timing(lv, target, fields) do
    lv
    |> element("#calendar-panel-timing")
    |> render_change(Map.put(fields, "_target", [target]))
  end

  defp timed(start_date, start_time, end_date, end_time),
    do: %{
      "start_date" => start_date,
      "start_time" => start_time,
      "end_date" => end_date,
      "end_time" => end_time
    }

  defp same?(a, b), do: DateTime.compare(a, b) == :eq

  test "shows the event's times on the organiser's clock", %{lv: lv, review: review} do
    edit(lv, review)

    assert has_element?(
             lv,
             "#calendar-panel-start-date-field [data-picker-value][value='2026-10-14']"
           )

    assert has_element?(lv, "#calendar-panel-start-time-field [data-picker-value][value='10:00']")
    assert has_element?(lv, "#calendar-panel-end-time-field [data-picker-value][value='11:00']")
  end

  test "a later start takes the end with it", %{lv: lv, review: review} do
    lv
    |> edit(review)
    |> change_timing("start_time", timed("2026-10-14", "11:30", "2026-10-14", "11:00"))

    uid = review.uid
    assert_receive {:written, ^uid, payload}
    assert same?(payload.start_time, ~U[2026-10-14 10:30:00Z])
    assert same?(payload.end_time, ~U[2026-10-14 11:30:00Z])
  end

  test "a new end leaves the start where it is", %{lv: lv, review: review} do
    lv
    |> edit(review)
    |> change_timing("end_time", timed("2026-10-14", "10:00", "2026-10-14", "12:30"))

    uid = review.uid
    assert_receive {:written, ^uid, payload}
    assert same?(payload.start_time, ~U[2026-10-14 09:00:00Z])
    assert same?(payload.end_time, ~U[2026-10-14 11:30:00Z])
  end

  test "an end before the start is refused in the field and writes nothing", %{
    lv: lv,
    review: review
  } do
    lv
    |> edit(review)
    |> change_timing("end_time", timed("2026-10-14", "10:00", "2026-10-14", "09:30"))

    assert has_element?(
             lv,
             "#calendar-panel",
             "The end is before the start. Pick a later end time."
           )

    refute_receive {:written, _uid, _payload}, 200
  end

  test "an end longer than a week away is refused", %{lv: lv, review: review} do
    lv
    |> edit(review)
    |> change_timing("end_date", timed("2026-10-14", "10:00", "2026-10-23", "11:00"))

    assert has_element?(lv, "#calendar-panel", "An event can last up to 7 days.")
    refute_receive {:written, _uid, _payload}, 200
  end

  test "the same times again write nothing", %{lv: lv, review: review} do
    lv
    |> edit(review)
    |> change_timing("start_time", timed("2026-10-14", "10:00", "2026-10-14", "11:00"))

    refute_receive {:written, _uid, _payload}, 200
  end

  # London leaves summer time at 02:00 on Sunday 25 October 2026. A two-hour
  # event from 00:30 to 02:30 on the Saturday, moved to 00:30 on the Sunday,
  # still lasts two hours: it ends at 01:30 GMT, not at 02:30.
  test "a start moved across the clock change keeps the event's real length", %{
    conn: conn,
    integration: integration
  } do
    late = event(integration, "work", "Night shift", ~U[2026-10-23 23:30:00Z], 120)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    lv
    |> edit(late)
    |> change_timing("start_date", timed("2026-10-25", "00:30", "2026-10-24", "02:30"))

    uid = late.uid
    assert_receive {:written, ^uid, payload}
    assert same?(payload.start_time, ~U[2026-10-24 23:30:00Z])
    assert same?(payload.end_time, ~U[2026-10-25 01:30:00Z])
  end

  describe "an all-day event" do
    setup %{conn: conn, integration: integration} do
      # Wednesday 14 and Thursday 15 October; the stored end is exclusive.
      offsite =
        event(integration, "work", "Offsite", ~U[2026-10-14 00:00:00Z], 60,
          all_day: true,
          start_at: nil,
          end_at: nil,
          start_date: ~D[2026-10-14],
          end_date: ~D[2026-10-16]
        )

      # The page loaded in the outer setup, before this event existed.
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      %{lv: lv, offsite: offsite}
    end

    test "shows its last day, not the stored end", %{lv: lv, offsite: offsite} do
      edit(lv, offsite)

      assert has_element?(
               lv,
               "#calendar-panel-end-date-field [data-picker-value][value='2026-10-15']"
             )

      refute has_element?(lv, "#calendar-panel-start-time")
    end

    test "a later last day is stored as the day after it", %{lv: lv, offsite: offsite} do
      lv
      |> edit(offsite)
      |> change_timing("end_date", %{"start_date" => "2026-10-14", "end_date" => "2026-10-17"})

      uid = offsite.uid
      assert_receive {:written, ^uid, payload}
      assert payload.start_time == ~D[2026-10-14]
      assert payload.end_time == ~D[2026-10-18]
    end

    test "a new first day keeps the number of days", %{lv: lv, offsite: offsite} do
      lv
      |> edit(offsite)
      |> change_timing("start_date", %{"start_date" => "2026-10-20", "end_date" => "2026-10-15"})

      uid = offsite.uid
      assert_receive {:written, ^uid, payload}
      assert payload.start_time == ~D[2026-10-20]
      assert payload.end_time == ~D[2026-10-22]
    end

    test "a last day before the first is refused", %{lv: lv, offsite: offsite} do
      lv
      |> edit(offsite)
      |> change_timing("end_date", %{"start_date" => "2026-10-14", "end_date" => "2026-10-13"})

      assert has_element?(
               lv,
               "#calendar-panel",
               "The end is before the start. Pick a later end date."
             )

      refute_receive {:written, _uid, _payload}, 200
    end

    test "a stay of more than 366 days is refused", %{lv: lv, offsite: offsite} do
      lv
      |> edit(offsite)
      |> change_timing("end_date", %{"start_date" => "2026-10-14", "end_date" => "2027-10-16"})

      assert has_element?(lv, "#calendar-panel", "An all-day event can last up to 366 days.")
      refute_receive {:written, _uid, _payload}, 200
    end

    test "a year the calendar cannot show is refused in its own words", %{
      lv: lv,
      offsite: offsite
    } do
      lv
      |> edit(offsite)
      |> change_timing("start_date", %{"start_date" => "2201-01-01", "end_date" => "2026-10-15"})

      assert has_element?(lv, "#calendar-panel", "Pick a date between 1900 and 2200.")
      refute has_element?(lv, "#calendar-panel", "up to 7 days")
      refute_receive {:written, _uid, _payload}, 200
    end

    test "All day off gives the day its working hours", %{lv: lv, offsite: offsite} do
      lv |> edit(offsite) |> element("#calendar-panel-all-day") |> render_click()

      uid = offsite.uid
      assert_receive {:written, ^uid, payload}
      refute payload.all_day
      # 09:00 on the first day to 10:00 on the last, London summer time.
      assert same?(payload.start_time, ~U[2026-10-14 08:00:00Z])
      assert same?(payload.end_time, ~U[2026-10-15 09:00:00Z])
    end

    test "a stay too long for a timed event cannot be switched to times", %{
      conn: conn,
      integration: integration
    } do
      trip =
        event(integration, "work", "Trip", ~U[2026-10-14 00:00:00Z], 60,
          all_day: true,
          start_at: nil,
          end_at: nil,
          start_date: ~D[2026-10-14],
          end_date: ~D[2026-10-26]
        )

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
      lv |> edit(trip) |> element("#calendar-panel-all-day") |> render_click()

      assert has_element?(lv, "#calendar-panel", "An event can last up to 7 days.")
      refute_receive {:written, _uid, _payload}, 200
    end
  end

  test "All day turns a timed event into a day", %{lv: lv, review: review} do
    lv |> edit(review) |> element("#calendar-panel-all-day") |> render_click()

    uid = review.uid
    assert_receive {:written, ^uid, payload}
    assert payload.all_day
    assert payload.start_time == ~D[2026-10-14]
    assert payload.end_time == ~D[2026-10-15]
  end

  test "undo after a start move writes both original instants back", %{lv: lv, review: review} do
    lv
    |> edit(review)
    |> change_timing("start_time", timed("2026-10-14", "11:30", "2026-10-14", "11:00"))

    uid = review.uid
    assert_receive {:written, ^uid, _moved}
    render(lv)

    lv |> element("#calendar-canvas") |> render_hook("calendar:undo", %{})

    assert_receive {:written, ^uid, payload}, 1_000
    assert same?(payload.start_time, ~U[2026-10-14 09:00:00Z])
    assert same?(payload.end_time, ~U[2026-10-14 10:00:00Z])
  end

  describe "an event whose timing cannot change" do
    defp hand_crafted(lv) do
      lv
      |> element("#calendar-canvas")
      |> render_hook("panel:timing", %{
        "_target" => ["start_time"],
        "start_date" => "2026-10-16",
        "start_time" => "12:00",
        "end_date" => "2026-10-16",
        "end_time" => "13:00"
      })

      render_hook(element(lv, "#calendar-canvas"), "panel:all_day", %{})
    end

    test "a booking writes nothing", %{conn: conn, user: user} do
      meeting =
        insert(:meeting,
          organizer_user: user,
          title: "Intro call",
          start_time: ~U[2026-10-16 10:00:00Z],
          end_time: ~U[2026-10-16 10:30:00Z],
          status: "confirmed"
        )

      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      lv
      |> element("#calendar-canvas")
      |> render_hook("calendar:edit", %{"id" => "booking-#{meeting.id}"})

      assert has_element?(lv, "fieldset[disabled] #calendar-panel-start-date")

      hand_crafted(lv)

      refute_receive {:written, _uid, _payload}, 200
    end

    test "a booking's calendar copy writes nothing", %{conn: conn, integration: integration} do
      copy = event(integration, "work", "Intro call", ~U[2026-10-16 10:00:00Z])
      insert(:meeting, calendar_integration_id: integration.id, calendar_uid: copy.uid)
      {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

      edit(lv, copy)
      hand_crafted(lv)

      refute_receive {:written, _uid, _payload}, 200
    end
  end
end
