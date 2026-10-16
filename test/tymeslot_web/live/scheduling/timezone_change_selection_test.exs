defmodule TymeslotWeb.Live.Scheduling.TimezoneChangeSelectionTest do
  @moduledoc """
  Pins what a timezone change does to the day selected on the schedule step.

  The page lands the booker on the first free day by itself. That day was
  chosen for the old zone's today, so after a change of timezone it can already
  be past, and was kept anyway: the calendar only followed a timezone change
  while no day was selected, and the page's own pick counted as a selection. A
  day the page picked is picked again for the new zone; a day the booker chose,
  by clicking it or through a `?date=` link, is theirs and stays, unless it is
  outside the booking window in the new zone, where nobody can book it.

  The connected LiveView runs in a process of its own, where `Tymeslot.Clock`
  cannot be frozen, so the tests move between two zones exactly 24 hours apart
  on the real clock: the second zone's today is always the first zone's
  tomorrow, and the first zone's today is always past there. The organiser is
  available around the clock, so the first free day in either zone is its
  today; the pair is picked so the starting zone is not in the last hour of its
  day, when today would have no time left to book.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :scheduling
  @moduletag :themes
  @moduletag :live
  @moduletag :integration

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Profiles
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks
  alias TymeslotWeb.ThemeTestMatrix

  # Each pair is 24 hours apart, and neither zone observes summer time.
  @zone_pairs [
    {"Pacific/Honolulu", "Pacific/Kiritimati"},
    {"Pacific/Pago_Pago", "Pacific/Tongatapu"}
  ]

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()
    TestMocks.setup_all_mocks()

    user = insert(:user, name: "Timezone Host")

    profile =
      insert(:profile,
        user: user,
        username: "tz-change-#{System.unique_integer([:positive])}",
        booking_theme: "1",
        timezone: "UTC"
      )

    schedule =
      insert(:availability_schedule,
        profile: profile,
        is_default: true,
        advance_booking_days: 30,
        min_advance_hours: 0,
        buffer_before_minutes: 0,
        buffer_after_minutes: 0
      )

    Enum.each(1..7, fn day_of_week ->
      insert(:weekly_availability,
        schedule: schedule,
        day_of_week: day_of_week,
        is_available: true,
        start_time: ~T[00:00:00],
        end_time: ~T[23:59:00]
      )
    end)

    meeting_type =
      insert(:meeting_type, user: user, name: "30 Minutes", duration_minutes: 30, is_active: true)

    insert(:calendar_integration, user: user, is_active: true)

    {from, to} = zone_pair()

    %{user: user, profile: profile, meeting_type: meeting_type, from: from, to: to}
  end

  # The day drawn selected on the calendar's day buttons; a week grid's week
  # follows a timezone change through WeekSlots (week_slots_flow_test.exs).
  for theme <- ThemeTestMatrix.all(), theme.schedule_view == :calendar do
    @theme theme

    describe "#{theme.slug}: a day the page picked" do
      setup %{profile: profile}, do: use_theme(profile, @theme)

      test "is picked again for the new timezone", %{conn: conn, profile: profile} = ctx do
        view = open_schedule(conn, "/#{profile.username}/30-minutes", ctx.from)
        assert_selected(view, today(ctx.from), "the page's own pick before the change")

        change_timezone(view, ctx.to)

        assert_selected(view, today(ctx.to), "the page's pick after moving to #{ctx.to}")
        assert has_element?(view, "button[data-testid='time-slot']")
      end

      test "has no slots fetched for it once the timezone has changed",
           %{conn: conn, profile: profile} = ctx do
        view = open_schedule(conn, "/#{profile.username}/30-minutes", ctx.from)
        old_day = Date.to_iso8601(today(ctx.from))
        new_day = Date.to_iso8601(today(ctx.to))
        assert live_assigns(view).selected_date == old_day

        # Slots are fetched synchronously in the LiveView, so a fetch for the
        # day about to be dropped holds the page up for nothing.
        :erlang.trace(view.pid, true, [:receive])
        change_timezone(view, ctx.to)
        :erlang.trace(view.pid, false, [:receive])
        await_trace_delivered(view)

        assert_received {:trace, _pid, :receive, {:load_slots, ^new_day}},
                        "expected the new day's slots to be loaded, or the trace saw nothing"

        refute_received {:trace, _pid, :receive, {:fetch_available_slots, ^old_day, _, _}},
                        "slots were fetched for #{old_day}, a day dropped by the change"
      end

      test "is picked again after a visit to the booking step and back",
           %{conn: conn, profile: profile} = ctx do
        view = open_schedule(conn, "/#{profile.username}/30-minutes", ctx.from)
        picked = today(ctx.from)
        assert_selected(view, picked, "the page's own pick")

        # Coming back, the schedule step reopens on the day as a held one, no
        # longer the page's: only the new zone's booking window can drop it.
        [time | _other_times] =
          view
          |> render()
          |> Floki.parse_document!()
          |> Floki.attribute("button[data-testid='time-slot']", "phx-value-time")

        send(view.pid, {:step_event, :schedule, :select_time, time})
        send(view.pid, {:step_event, :schedule, :next_step, nil})
        wait_until(fn -> live_assigns(view).current_state == :booking end)
        send(view.pid, {:step_event, :booking, :back_step, nil})
        wait_until(fn -> settled?(view) end)
        assert_selected(view, picked, "the held day back on the schedule step")

        change_timezone(view, ctx.to)

        assert_selected(view, today(ctx.to), "the pick after #{picked} passed in #{ctx.to}")
      end

      test "is picked again on every later change of timezone",
           %{conn: conn, profile: profile} = ctx do
        view = open_schedule(conn, "/#{profile.username}/30-minutes", ctx.from)

        change_timezone(view, ctx.to)
        assert_selected(view, today(ctx.to), "the page's pick after the first change")

        # The second pick is the page's too; taken for the booker's, it would
        # keep a day that is not yet bookable back in the first zone.
        change_timezone(view, ctx.from)
        assert_selected(view, today(ctx.from), "the page's pick after changing back")
      end

      test "on a reschedule is picked again for the new timezone",
           %{conn: conn, profile: profile} = ctx do
        meeting = insert_meeting(ctx)

        view =
          open_schedule(
            conn,
            "/#{profile.username}?reschedule_meeting_uid=#{meeting.uid}",
            ctx.from,
            :from_overview
          )

        assert live_assigns(view).is_rescheduling
        assert_selected(view, today(ctx.from), "the reschedule's landing before the change")

        change_timezone(view, ctx.to)

        assert_selected(view, today(ctx.to), "the reschedule's landing after the change")
      end
    end

    describe "#{theme.slug}: a day the booker chose" do
      setup %{profile: profile}, do: use_theme(profile, @theme)

      test "survives a change of timezone, with its times reloaded for the new zone",
           %{conn: conn, profile: profile} = ctx do
        view = open_schedule(conn, "/#{profile.username}/30-minutes", ctx.from)
        chosen = Date.add(today(ctx.from), 3)
        click_day(view, chosen)
        assert_selected(view, chosen, "the clicked day")

        :erlang.trace(view.pid, true, [:receive])
        change_timezone(view, ctx.to)
        :erlang.trace(view.pid, false, [:receive])
        await_trace_delivered(view)

        assert_selected(view, chosen, "the clicked day after moving to #{ctx.to}")
        chosen_string = Date.to_iso8601(chosen)
        to = ctx.to

        assert_received {:trace, _pid, :receive,
                         {:fetch_available_slots, ^chosen_string, _duration, ^to}}

        assert has_element?(view, "button[data-testid='time-slot']")
      end

      test "is dropped once it has passed in the new timezone",
           %{conn: conn, profile: profile} = ctx do
        # Opened on tomorrow through a link, so the page never picks today:
        # the booker's click on today is theirs alone, and only the new
        # zone's booking window can drop it. (Clicking the day the page
        # picked would leave the calendar where the page left it, and follow
        # the change for that reason instead.)
        tomorrow = Date.add(today(ctx.from), 1)
        view = open_schedule(conn, "/#{profile.username}/30-minutes?date=#{tomorrow}", ctx.from)
        clicked = today(ctx.from)
        click_day(view, clicked)
        assert_selected(view, clicked, "the clicked day")

        change_timezone(view, ctx.to)

        assert_selected(view, today(ctx.to), "the pick after #{clicked} passed in #{ctx.to}")
      end

      test "through a ?date= link survives a change of timezone",
           %{conn: conn, profile: profile} = ctx do
        linked = Date.add(today(ctx.from), 3)
        view = open_schedule(conn, "/#{profile.username}/30-minutes?date=#{linked}", ctx.from)
        assert_selected(view, linked, "the linked day")

        change_timezone(view, ctx.to)

        assert_selected(view, linked, "the linked day after moving to #{ctx.to}")
      end

      test "on a reschedule survives a change of timezone",
           %{conn: conn, profile: profile} = ctx do
        meeting = insert_meeting(ctx)

        view =
          open_schedule(
            conn,
            "/#{profile.username}?reschedule_meeting_uid=#{meeting.uid}",
            ctx.from,
            :from_overview
          )

        chosen = Date.add(today(ctx.from), 3)
        click_day(view, chosen)
        assert_selected(view, chosen, "the clicked day on the reschedule")

        change_timezone(view, ctx.to)

        assert_selected(view, chosen, "the clicked day on the reschedule after the change")
      end
    end
  end

  defp use_theme(profile, theme) do
    {:ok, profile} = Profiles.update_profile(profile, %{booking_theme: theme.id})
    %{profile: profile}
  end

  # The starting zone must have time left to book today, or the page's first
  # pick would already be its tomorrow. The zones of the second pair are an
  # hour behind the first's, so one of them always has.
  defp zone_pair do
    now = DateTime.utc_now()

    Enum.find(@zone_pairs, fn {from, _to} -> DateTime.shift_zone!(now, from).hour < 23 end)
  end

  defp open_schedule(conn, path, timezone, entry \\ :direct) do
    separator = if String.contains?(path, "?"), do: "&", else: "?"

    {:ok, view, _html} =
      conn
      |> put_connect_params(%{"timezone" => timezone})
      |> live("#{path}#{separator}timezone=#{timezone}")

    if entry == :from_overview do
      view |> element("button[data-testid='duration-option']") |> render_click()
      view |> element("button[data-testid='next-step']") |> render_click()
    end

    wait_until(fn -> settled?(view) end)
    view
  end

  defp change_timezone(view, timezone) do
    # The message the schedule step's timezone picker relays for a pick.
    send(view.pid, {:step_event, :schedule, :change_timezone, timezone})
    wait_until(fn -> live_assigns(view).user_timezone == timezone and settled?(view) end)
  end

  # The month's availability has arrived, the landing has run on it, and the
  # selected day's times have loaded.
  defp settled?(view) do
    assigns = live_assigns(view)

    assigns.current_state == :schedule and assigns.availability_task_ref == nil and
      assigns.availability_status == :loaded and assigns.auto_select_settled == true and
      assigns.loading_slots != true
  end

  # Trace messages reach the tracer asynchronously; this waits until every one
  # for the view has arrived, so the mailbox can be read as complete.
  defp await_trace_delivered(view) do
    ref = :erlang.trace_delivered(view.pid)
    assert_receive {:trace_delivered, _pid, ^ref}
  end

  # Brings the day's week on screen, as the week arrows would, then clicks it:
  # the message the schedule step relays for a click on a day.
  defp click_day(view, %Date{} = date) do
    shown = live_assigns(view).current_week_start
    wanted = Date.beginning_of_week(date, :monday)

    if shown != wanted do
      arrow = if Date.compare(wanted, shown) == :gt, do: :next_week, else: :prev_week
      send(view.pid, {:step_event, :schedule, arrow, nil})
      wait_until(fn -> settled?(view) end)
    end

    send(view.pid, {:step_event, :schedule, :select_date, Date.to_iso8601(date)})
  end

  defp assert_selected(view, %Date{} = expected, what) do
    wait_until(fn -> settled?(view) end)
    %{selected_date: selected, user_timezone: zone} = live_assigns(view)
    expected = Date.to_iso8601(expected)

    assert selected == expected,
           "expected #{what} to be #{expected} (today in #{zone} is #{today(zone)}), " <>
             "found #{inspect(selected)}"

    assert drawn_selected(view) == [expected],
           "expected #{what}, #{expected}, to be drawn selected, " <>
             "found #{inspect(drawn_selected(view))}"
  end

  # The days drawn selected, across both themes' day buttons (Quill's month
  # grid and narrow-screen week row, Rhythm's week strip).
  defp drawn_selected(view) do
    view
    |> render()
    |> Floki.parse_document!()
    |> Floki.find("button[phx-click='select_date'][phx-value-date]")
    |> Enum.filter(fn button ->
      classes = button |> Floki.attribute("class") |> List.first("") |> String.split()
      "selected" in classes or "calendar-day--selected" in classes
    end)
    |> Floki.attribute("phx-value-date")
    |> Enum.uniq()
  end

  defp insert_meeting(%{user: user, meeting_type: meeting_type}) do
    start = DateTime.utc_now() |> DateTime.add(10, :day) |> DateTime.truncate(:second)

    insert(:meeting,
      organizer_user_id: user.id,
      organizer_name: user.name,
      meeting_type_id: meeting_type.id,
      attendee_name: "Test Attendee",
      attendee_email: "attendee@example.com",
      attendee_timezone: "UTC",
      start_time: start,
      end_time: DateTime.add(start, 30, :minute),
      duration: 30,
      status: "confirmed"
    )
  end

  defp today(zone), do: zone |> DateTime.now!() |> DateTime.to_date()

  defp live_assigns(view), do: :sys.get_state(view.pid).socket.assigns
end
