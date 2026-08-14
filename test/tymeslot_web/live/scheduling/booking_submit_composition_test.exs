defmodule TymeslotWeb.Live.Scheduling.BookingSubmitCompositionTest do
  @moduledoc """
  Composition tests for the public booking submit entry point.

  `handle_event("submit", ...)` on the theme booking components was only
  covered by happy-path + honeypot tests. This file pins the
  distinguishable error flashes that must reach the user when state
  changes between the page render and the submit — the edges that, if
  regressed, would surface as a stack trace or a generic failure flash
  instead of the specific "try again" nudges the UI promises.

  Two scenarios covered:

    * **TOCTOU slot race** — user picks a slot, an organiser event appears
      on the calendar, submit fires. The calendar pre-check must reject
      the slot and surface the "no longer available" flash. Without this
      we'd double-book silently (before fresh-check) or crash (if the
      error atom ever stops being mapped). The booker must also be bounced
      back to the schedule step with the stale time cleared — not stranded
      on the form re-submitting a dead slot.

    * **Meeting type deactivated mid-flow** — the organiser toggles a
      meeting type off while the attendee is on the form step. The
      validation layer must produce the "refresh the page" flash rather
      than a generic "please try again".

  The two other scenarios in the original audit (nil selected_date/time
  on deep-link; organiser profile deactivated) are not reachable via the
  current UI — the flow's own transition gates prevent them, and there
  is no `Profile.is_active` field. Those would require product changes
  before a meaningful regression test can exist.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :scheduling
  @moduletag :live

  import Mox
  import Tymeslot.Factory
  import Tymeslot.BookingTestHelpers

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()

    # Disable reCAPTCHA so we don't have to wire a token through the
    # form — we're exercising availability/validation branches that run
    # regardless of the security gate.
    old_cfg = Application.get_env(:tymeslot, :recaptcha, [])
    Application.put_env(:tymeslot, :recaptcha, Keyword.put(old_cfg, :booking_enabled, false))
    on_exit(fn -> Application.put_env(:tymeslot, :recaptcha, old_cfg) end)

    TestMocks.setup_all_mocks()

    user = insert(:user)

    profile =
      insert(:profile,
        user: user,
        username: "picker",
        booking_theme: "1",
        timezone: "America/New_York"
      )

    schedule =
      insert(:availability_schedule,
        profile: profile,
        is_default: true,
        advance_booking_days: 30,
        min_advance_hours: 0,
        buffer_minutes: 0
      )

    meeting_type =
      insert(:meeting_type,
        user: user,
        duration_minutes: 30,
        name: "Quick Chat",
        is_active: true
      )

    Enum.each(1..7, fn day_of_week ->
      insert(:weekly_availability,
        schedule: schedule,
        day_of_week: day_of_week,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )
    end)

    insert(:calendar_integration, user: user, is_active: true)

    %{profile: profile, meeting_type: meeting_type, user: user}
  end

  @tag :capture_log
  test "slot becomes unavailable between render and submit → flash, no crash, back to schedule",
       %{conn: conn, profile: profile, meeting_type: meeting_type} do
    view = navigate_to_booking_form(conn, profile, meeting_type)

    # Simulate the organiser's calendar sprouting an event that covers
    # the just-picked slot between the render and the submit. The fresh
    # pre-check in `Bookings.Create.execute_with_video_room/3` calls
    # `Tymeslot.CalendarMock.get_events_for_range_fresh/3`, so we
    # override that stub with an all-day event rooted at the selected
    # date — any 30-minute slot the user could have picked collides.
    %{selected_date: selected_date} = :sys.get_state(view.pid).socket.assigns
    date = if is_binary(selected_date), do: Date.from_iso8601!(selected_date), else: selected_date

    blocking_start =
      date
      |> DateTime.new!(~T[00:00:00], profile.timezone)
      |> DateTime.shift_zone!("Etc/UTC")

    blocking_end = DateTime.add(blocking_start, 24 * 60 * 60, :second)

    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      {:ok,
       [
         TestMocks.mock_calendar_event(
           summary: "Organiser double-book",
           start_time: blocking_start,
           end_time: blocking_end
         )
       ]}
    end)

    view
    |> form("form[phx-submit='submit']", %{
      "booking" => %{
        "name" => "Late Lucy",
        "email" => "late@example.com",
        "message" => "Hope this still works"
      }
    })
    |> render_submit()

    drained = :sys.get_state(view.pid)

    rendered = render(view)
    assert rendered =~ "select a different time"
    refute rendered =~ "Meeting Confirmed"

    # Recovery: the booker is returned to the schedule step with the now-dead
    # slot cleared, rather than left on the form re-submitting it.
    assert drained.socket.assigns.current_state == :schedule
    assert drained.socket.assigns.selected_time == nil
    refute has_element?(view, "form[phx-submit='submit']")

    # The day's slots are reloaded on the bounce-back (the queued
    # {:load_slots, date} was drained by :sys.get_state above); with the whole
    # day blocked the just-taken time is gone, so the booker sees a fresh,
    # empty slot list rather than the stale slot they lost the race on.
    assert drained.socket.assigns.available_slots == []
  end

  @tag :capture_log
  test "host's booking limit reached between render and submit → limit flash, back to schedule",
       %{conn: conn, profile: profile, meeting_type: meeting_type, user: user} do
    # The host caps bookings at 1/day; the page renders while the day still
    # has capacity.
    {:ok, _profile} = Profiles.update_booking_limit(profile, :max_bookings_per_day, 1)

    view = navigate_to_booking_form(conn, profile, meeting_type)

    # Another booker wins the day's last slot between render and submit.
    %{selected_date: selected_date} = :sys.get_state(view.pid).socket.assigns
    date = if is_binary(selected_date), do: Date.from_iso8601!(selected_date), else: selected_date

    competitor_start =
      date
      |> DateTime.new!(~T[12:00:00], profile.timezone)
      |> DateTime.shift_zone!("Etc/UTC")

    insert(:meeting,
      organizer_user_id: user.id,
      start_time: competitor_start,
      end_time: DateTime.add(competitor_start, 30, :minute)
    )

    view
    |> form("form[phx-submit='submit']", %{
      "booking" => %{
        "name" => "Capped Cara",
        "email" => "capped@example.com",
        "message" => "One too many"
      }
    })
    |> render_submit()

    drained = :sys.get_state(view.pid)

    rendered = render(view)
    assert rendered =~ "no longer accepting bookings"
    refute rendered =~ "Meeting Confirmed"

    # Same recovery as a sniped slot: back to the schedule step with the
    # stale time cleared and the day's slots reloaded — which the limit
    # checker now filters to empty, matching the greyed-out day.
    assert drained.socket.assigns.current_state == :schedule
    assert drained.socket.assigns.selected_time == nil
    assert drained.socket.assigns.available_slots == []
  end

  @tag :capture_log
  test "meeting type deactivated between step transition and submit → 'refresh the page' flash",
       %{conn: conn, profile: profile, meeting_type: meeting_type} do
    view = navigate_to_booking_form(conn, profile, meeting_type)

    # Organiser flips the meeting type off while the attendee sits on
    # the form step. The flow's active-type validation must win and
    # produce the "refresh the page" nudge — not the generic "try
    # again" that every other reason collapses to.
    {:ok, _deactivated} = MeetingTypes.update_meeting_type(meeting_type, %{is_active: false})

    view
    |> form("form[phx-submit='submit']", %{
      "booking" => %{
        "name" => "Stale Sam",
        "email" => "stale@example.com",
        "message" => "Still here!"
      }
    })
    |> render_submit()

    _drain = :sys.get_state(view.pid)

    rendered = render(view)
    assert rendered =~ "refresh the page"
    refute rendered =~ "Meeting Confirmed"
  end
end
