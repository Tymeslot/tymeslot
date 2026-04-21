defmodule TymeslotWeb.Live.Scheduling.DispatcherCancelCompositionTest do
  @moduledoc """
  Composition tests for the dispatcher's cancel/keep meeting entry
  points — `TymeslotWeb.Themes.Core.Dispatcher.handle_event/3` with
  `live_action: :cancel`, delegating to
  `TymeslotWeb.Themes.Core.MeetingManagement`.

  Covered gaps from the public audit:

    * Cancel on an already-cancelled meeting — the validation layer
      must surface a clean error page on mount, never crash or
      silently double-cancel.
    * Cancel of a meeting that already started — the time-policy gate
      must win before we ever reach the Bookings.Cancel module.
    * Rate-limit exceeded on cancel — user sees a specific flash and
      the meeting stays 'confirmed' in the DB; the rate limiter is
      the only defence against an attacker spamming cancels.
    * `keep_meeting` click — flips the socket flag and renders the
      kept view without touching the DB row.

  Reschedule is not exercised here — the reschedule route reuses the
  full booking flow, whose happy and error paths are already covered
  by `public_booking_happy_path_test.exs` and the new
  `booking_submit_composition_test.exs`.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :scheduling
  @moduletag :live

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    TestMocks.setup_all_mocks()

    user = insert(:user)

    profile =
      insert(:profile,
        user: user,
        username: "canceller",
        booking_theme: "1",
        timezone: "America/New_York"
      )

    %{user: user, profile: profile}
  end

  @tag :capture_log
  test "mount of cancel route for an already-cancelled meeting surfaces a clean error page",
       %{conn: conn, user: user, profile: profile} do
    meeting =
      insert(:meeting,
        organizer_user: user,
        organizer_user_id: user.id,
        organizer_name: user.name,
        attendee_timezone: profile.timezone,
        status: "cancelled"
      )

    # The dispatcher's `validate_and_load_meeting/3` blocks before the
    # cancel button is rendered — it redirects home with a flash from
    # `Policy.can_cancel_meeting?/1`. The user cannot reach the cancel
    # UI for an already-cancelled meeting, which is exactly what we
    # want — the alternative (rendering cancel + silently no-oping on
    # click) would confuse attendees and organisers alike.
    assert {:error, {:redirect, %{to: "/", flash: flash}}} =
             live(conn, "/#{profile.username}/meeting/#{meeting.uid}/cancel")

    assert flash["error"] =~ "already cancelled"
  end

  @tag :capture_log
  test "mount of cancel route for a past meeting is refused by the time policy",
       %{conn: conn, user: user, profile: profile} do
    past_start =
      DateTime.utc_now()
      |> DateTime.add(-2, :hour)
      |> DateTime.truncate(:second)

    meeting =
      insert(:meeting,
        organizer_user: user,
        organizer_user_id: user.id,
        organizer_name: user.name,
        attendee_timezone: profile.timezone,
        status: "confirmed",
        start_time: past_start,
        end_time: DateTime.add(past_start, 30 * 60, :second)
      )

    # The time-policy branch fires inside `validate_and_load_meeting/3`
    # — "has already started" / "has already occurred" depending on
    # the offset. Either way the user is kicked home with a flash
    # rather than landing on a stale cancel page.
    assert {:error, {:redirect, %{to: "/", flash: flash}}} =
             live(conn, "/#{profile.username}/meeting/#{meeting.uid}/cancel")

    assert flash["error"] =~ "already"
  end

  @tag :capture_log
  test "cancel-click when the rate limit is exhausted preserves the meeting and flashes the limiter's message",
       %{conn: conn, user: user, profile: profile} do
    meeting =
      insert(:meeting,
        organizer_user: user,
        organizer_user_id: user.id,
        organizer_name: user.name,
        attendee_timezone: profile.timezone,
        status: "confirmed"
      )

    {:ok, view, _html} =
      live(conn, "/#{profile.username}/meeting/#{meeting.uid}/cancel")

    # The scheduling LiveView captures client_ip during mount; the rate
    # limiter keys on that exact string. Saturate the cancel bucket for
    # the mount's IP so the next click lands in the `{:error,
    # :rate_limited, _}` arm of `MeetingManagement.handle_meeting_event/3`.
    client_ip = :sys.get_state(view.pid).socket.assigns[:client_ip] || "unknown"

    Enum.each(1..10, fn _i ->
      RateLimiter.check_meeting_cancel_rate_limit(client_ip)
    end)

    view |> element("[data-testid='cancel-meeting']") |> render_click()

    rendered = render(view)
    assert rendered =~ "limit of 10 meeting cancellation"

    # Meeting must NOT be cancelled — otherwise a rate-limited attacker
    # is still succeeding, which defeats the limiter.
    assert Repo.get!(MeetingSchema, meeting.id).status == "confirmed"
  end

  @tag :capture_log
  test "keep_meeting click flips the view into the kept state without touching the DB",
       %{conn: conn, user: user, profile: profile} do
    meeting =
      insert(:meeting,
        organizer_user: user,
        organizer_user_id: user.id,
        organizer_name: user.name,
        attendee_timezone: profile.timezone,
        status: "confirmed"
      )

    {:ok, view, _html} =
      live(conn, "/#{profile.username}/meeting/#{meeting.uid}/cancel")

    view |> element("[data-testid='keep-meeting']") |> render_click()

    rendered = render(view)
    assert rendered =~ "still scheduled as planned"

    assert Repo.get!(MeetingSchema, meeting.id).status == "confirmed"
  end
end
