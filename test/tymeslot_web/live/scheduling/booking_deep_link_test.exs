defmodule TymeslotWeb.Live.Scheduling.BookingDeepLinkTest do
  @moduledoc """
  `/:username/:slug/book` is a real, directly enterable route: a visitor can
  paste it, and a confirmation email's links point into the same flow. Entering
  it that way runs no state transition, so nothing upstream has resolved the
  slug into a meeting type.

  Without that resolution the submission carries `meeting_type_id: nil`, which
  the domain waves through, and the duration falls back to parsing the slug —
  with no upper bound, so `/host/99999/book` would hold a multi-day slot.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :scheduling
  @moduletag :live

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()
    TestMocks.setup_all_mocks()

    user = insert(:user)

    profile =
      insert(:profile,
        user: user,
        username: "deeplinkhost",
        booking_theme: "1",
        timezone: "Etc/UTC"
      )

    schedule =
      insert(:availability_schedule,
        profile: profile,
        is_default: true,
        advance_booking_days: 30,
        min_advance_hours: 0,
        buffer_minutes: 0
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

    meeting_type =
      insert(:meeting_type,
        user: user,
        duration_minutes: 45,
        name: "Deep Dive",
        is_active: true
      )

    insert(:calendar_integration, user: user, is_active: true)

    date = Date.to_string(Date.add(Date.utc_today(), 3))

    %{profile: profile, meeting_type: meeting_type, date: date}
  end

  @tag :capture_log
  test "landing straight on the booking step resolves the meeting type from the slug",
       %{conn: conn, profile: profile, meeting_type: meeting_type, date: date} do
    {:ok, view, _html} =
      live(conn, "/#{profile.username}/deep-dive/book?date=#{date}&time=10:00%20AM")

    assigns = :sys.get_state(view.pid).socket.assigns

    assert assigns.meeting_type.id == meeting_type.id
    assert assigns.meeting_type.duration_minutes == 45
  end

  @tag :capture_log
  test "a slug naming no meeting type is refused rather than booked at its face value",
       %{conn: conn, profile: profile, date: date} do
    # "99999" parses to 99999 minutes — a 69-day hold — if it is ever allowed
    # to stand in for a duration.
    assert {:error, {:redirect, %{to: to, flash: flash}}} =
             live(conn, "/#{profile.username}/99999/book?date=#{date}&time=10:00%20AM")

    assert to == "/#{profile.username}"
    assert flash["error"] =~ "Invalid meeting type"
  end

  @tag :capture_log
  test "an unresolvable slug on the schedule step is refused the same way",
       %{conn: conn, profile: profile} do
    assert {:error, {:redirect, %{to: to}}} =
             live(conn, "/#{profile.username}/99999")

    assert to == "/#{profile.username}"
  end

  @tag :capture_log
  test "a reschedule link whose uid no longer resolves still resolves the meeting type from the slug",
       %{conn: conn, profile: profile, meeting_type: meeting_type} do
    {:ok, view, _html} =
      live(
        conn,
        "/#{profile.username}/deep-dive/book?reschedule_meeting_uid=does-not-exist"
      )

    assigns = :sys.get_state(view.pid).socket.assigns

    assert assigns.meeting_type.id == meeting_type.id
  end
end
