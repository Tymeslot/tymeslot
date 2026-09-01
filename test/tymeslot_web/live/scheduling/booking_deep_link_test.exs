defmodule TymeslotWeb.Live.Scheduling.BookingDeepLinkTest do
  @moduledoc """
  `/:username/:slug/book` is a real, directly enterable route: a visitor can
  paste it, and a confirmation email's links point into the same flow. Entering
  it that way runs no state transition, so nothing upstream has resolved the
  slug into a meeting type.

  Without that resolution the submission carries `meeting_type_id: nil`, which
  the domain waves through, and the duration falls back to parsing the slug —
  with no upper bound, so `/host/99999/book` would hold a multi-day slot.

  The second half of the file covers the other thing a pasted URL can do:
  supply a parameter of a shape the flow never anticipated. Phoenix decodes
  `?date[]=x` to a list and `?date[a]=b` to a map, and every consumer below is
  written for strings, so an unguarded assign raises in `Date.from_iso8601/1`
  or `normalize_duration_slug/1`. `Themes.Core.ErrorBoundary` rescues the
  raise, which is why the assertions here are not about the process staying
  alive: what it leaves behind is the theme's error page in place of the
  booking flow, for anyone with the link, on a public page.
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

  describe "query parameters of an unexpected shape" do
    @tag :capture_log
    test "a list-shaped date is dropped and the day is picked for the booker instead",
         %{conn: conn, profile: profile, date: date} do
      {:ok, view, _html} =
        live(conn, "/#{profile.username}/deep-dive?date%5B%5D=#{date}")

      assert_landed_on_a_real_day(view)
    end

    @tag :capture_log
    test "a map-shaped date is dropped and the day is picked for the booker instead",
         %{conn: conn, profile: profile, date: date} do
      {:ok, view, _html} =
        live(conn, "/#{profile.username}/deep-dive?date%5Bon%5D=#{date}")

      assert_landed_on_a_real_day(view)
    end

    @tag :capture_log
    test "a date string that does not parse is dropped rather than stranding the step",
         %{conn: conn, profile: profile} do
      # `NextAvailable` stands down for any non-empty `:selected_date`, so a
      # value left on the socket here would park the booker on a schedule step
      # with no day selected and a calendar-parsing error where the times go.
      {:ok, view, _html} =
        live(conn, "/#{profile.username}/deep-dive?date=2026-02-31")

      assert_landed_on_a_real_day(view)
    end

    @tag :capture_log
    test "a list-shaped duration leaves the overview page rendering its durations",
         %{conn: conn, profile: profile} do
      # `/:username` has no `slug` path segment, so `?duration=` is what the
      # duration normaliser is handed. It raises earlier than the date does —
      # inside `handle_param_updates/2` itself, so on the very first render.
      {:ok, view, _html} = live(conn, "/#{profile.username}?duration%5B%5D=45min")

      # The real overview, not the error boundary's page standing in for it.
      assert has_element?(view, "button[data-testid='duration-option']")

      assigns = :sys.get_state(view.pid).socket.assigns

      assert assigns[:theme_error] == nil
      assert assigns.duration == nil
      assert assigns.selected_duration == nil
    end

    @tag :capture_log
    test "list-shaped time and reschedule parameters are treated as absent",
         %{conn: conn, profile: profile, date: date} do
      {:ok, view, _html} =
        live(
          conn,
          "/#{profile.username}/deep-dive?date=#{date}" <>
            "&time%5B%5D=10:00%20AM&reschedule_meeting_uid%5B%5D=abc"
        )

      assigns = :sys.get_state(view.pid).socket.assigns

      assert assigns.selected_date == date
      assert assigns.selected_time == nil
      assert assigns.reschedule_meeting_uid == nil

      # A uid that never landed must not leave the flow believing it is
      # rescheduling: the submit path branches on this assign alone.
      refute assigns.is_rescheduling
    end
  end

  # The booker is on a day the organiser actually offers — which is only
  # possible because the malformed parameter was dropped early enough for the
  # next-available search to run.
  defp assert_landed_on_a_real_day(view) do
    wait_until(fn -> :sys.get_state(view.pid).socket.assigns[:selected_date] != nil end)

    selected_date = :sys.get_state(view.pid).socket.assigns.selected_date

    assert {:ok, %Date{}} = Date.from_iso8601(selected_date)
    assert render(view) =~ selected_date
  end
end
