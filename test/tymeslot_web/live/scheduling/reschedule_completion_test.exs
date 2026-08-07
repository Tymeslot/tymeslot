defmodule TymeslotWeb.Live.Scheduling.RescheduleCompletionTest do
  @moduledoc """
  Journey coverage for a booker completing a reschedule through the public
  scheduling page.

  What already existed was the two ends of the journey and nothing in
  between: `Tymeslot.Bookings.RescheduleTest` covers the domain function,
  and the theme meeting-page tests cover the reschedule *landing page* —
  that it renders, and that "Choose New Time" redirects to
  `/:username?reschedule_meeting_uid=…`. `DispatcherCancelCompositionTest`
  says as much in its own moduledoc: "Reschedule is not exercised here."

  The untested middle is where the bug lives. `LiveHelpers` turns that
  query param into `is_rescheduling`, `PathHandlers` has to carry it across
  every step transition, and `BookingSubmissionHandlerComponent` reads it
  back off the socket to choose between `Create` and `Reschedule`. Drop the
  param anywhere along that chain and the flow still succeeds — it just
  books a second meeting and leaves the original in place. The attendee sees
  a confirmation either way, so nothing surfaces the fault.

  Hence the load-bearing assertion in each test below: the organiser still
  owns exactly one meeting afterwards.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :scheduling
  @moduletag :bookings
  @moduletag :live
  @moduletag :integration

  use Oban.Testing, repo: Tymeslot.Repo

  import Ecto.Query, only: [where: 2]
  import Mox
  import Tymeslot.BookingTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.CalendarEventWorker

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    AvailabilityCache.clear_all()
    TestMocks.setup_all_mocks()

    timezone = "UTC"
    user = insert(:user, name: "Test Organizer")

    profile =
      insert(:profile,
        user: user,
        username: "reschedule-host",
        booking_theme: "1",
        timezone: timezone,
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
        profile: profile,
        day_of_week: day_of_week,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )
    end)

    _integration = insert(:calendar_integration, user: user, is_active: true)

    # The meeting being moved: far enough out that Policy's "already started"
    # and "already occurred" guards both pass. Truncated to the second because
    # `start_time` is `:utc_datetime` — without this the round-tripped value
    # never equals the one held here, and every "did it move?" assertion
    # passes whether or not anything moved.
    original_start =
      DateTime.utc_now() |> DateTime.add(7, :day) |> DateTime.truncate(:second)

    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        organizer_name: user.name,
        meeting_type_id: meeting_type.id,
        attendee_name: "Test Attendee",
        attendee_email: "attendee@example.com",
        attendee_timezone: timezone,
        start_time: original_start,
        end_time: DateTime.add(original_start, 30, :minute),
        duration: 30,
        status: "confirmed"
      )

    %{
      user: user,
      profile: profile,
      meeting_type: meeting_type,
      meeting: meeting,
      original_start: original_start
    }
  end

  describe "completing a reschedule from the public scheduling page" do
    @tag :capture_log
    test "moves the existing meeting instead of creating a second one", %{
      conn: conn,
      user: user,
      profile: profile,
      meeting_type: meeting_type,
      meeting: meeting,
      original_start: original_start
    } do
      view =
        navigate_to_booking_form(conn, profile, meeting_type, reschedule_meeting_uid: meeting.uid)

      view
      |> form("form[phx-submit='submit']", %{
        "booking" => %{
          "name" => "Test Attendee",
          "email" => "attendee@example.com",
          "message" => "Something came up"
        }
      })
      |> render_submit()

      wait_until(fn ->
        Repo.get!(MeetingSchema, meeting.id).start_time != original_start
      end)

      moved = Repo.get!(MeetingSchema, meeting.id)

      assert DateTime.compare(moved.start_time, original_start) != :eq,
             "expected the meeting to be moved to the newly selected slot"

      assert moved.status == "confirmed",
             "a reschedule moves the meeting; it must not change its lifecycle status"

      assert meeting_count_for(user) == 1,
             "rescheduling must move the existing meeting, not book a duplicate"
    end

    @tag :capture_log
    test "clears reminder tracking so reminders re-pin to the new time", %{
      conn: conn,
      profile: profile,
      meeting_type: meeting_type,
      meeting: meeting,
      original_start: original_start
    } do
      # A reminder already went out for the original slot. Leaving that
      # tracking in place would suppress the reminder for the new time.
      meeting
      |> Changeset.change(%{
        reminder_email_sent: true,
        reminders_sent: [%{"value" => 24, "unit" => "hours"}]
      })
      |> Repo.update!()

      view =
        navigate_to_booking_form(conn, profile, meeting_type, reschedule_meeting_uid: meeting.uid)

      view
      |> form("form[phx-submit='submit']", %{
        "booking" => %{
          "name" => "Test Attendee",
          "email" => "attendee@example.com",
          "message" => ""
        }
      })
      |> render_submit()

      wait_until(fn ->
        Repo.get!(MeetingSchema, meeting.id).start_time != original_start
      end)

      moved = Repo.get!(MeetingSchema, meeting.id)

      refute moved.reminder_email_sent
      assert moved.reminders_sent == []
    end

    @tag :capture_log
    test "schedules the organiser's calendar event to move with it", %{
      conn: conn,
      profile: profile,
      meeting_type: meeting_type,
      meeting: meeting,
      original_start: original_start
    } do
      view =
        navigate_to_booking_form(conn, profile, meeting_type, reschedule_meeting_uid: meeting.uid)

      view
      |> form("form[phx-submit='submit']", %{
        "booking" => %{
          "name" => "Test Attendee",
          "email" => "attendee@example.com",
          "message" => ""
        }
      })
      |> render_submit()

      wait_until(fn ->
        Repo.get!(MeetingSchema, meeting.id).start_time != original_start
      end)

      # The booker moving the slot has to move the organiser's provider
      # calendar entry too, or the organiser's own calendar keeps blocking the
      # old time and showing the meeting where it no longer is.
      assert_enqueued(
        worker: CalendarEventWorker,
        args: %{"action" => "update", "meeting_id" => meeting.id}
      )
    end
  end

  describe "without the reschedule context" do
    @tag :capture_log
    test "the same walk books a new meeting and leaves the original alone", %{
      conn: conn,
      user: user,
      profile: profile,
      meeting_type: meeting_type,
      meeting: meeting,
      original_start: original_start
    } do
      # The contrast case. Identical steps, no `reschedule_meeting_uid` — if
      # this produced the same outcome as the test above, that test would be
      # passing for the wrong reason.
      view = navigate_to_booking_form(conn, profile, meeting_type)

      view
      |> form("form[phx-submit='submit']", %{
        "booking" => %{
          "name" => "Someone Else",
          "email" => "someone-else@example.com",
          "message" => ""
        }
      })
      |> render_submit()

      wait_until(fn -> meeting_count_for(user) == 2 end)

      untouched = Repo.get!(MeetingSchema, meeting.id)
      assert DateTime.compare(untouched.start_time, original_start) == :eq
    end
  end

  defp meeting_count_for(user) do
    MeetingSchema
    |> where(organizer_user_id: ^user.id)
    |> Repo.aggregate(:count)
  end
end
