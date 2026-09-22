defmodule TymeslotWeb.Live.Scheduling.RescheduleCompletionTest do
  @moduledoc """
  Journey coverage for a booker completing a reschedule through the public
  scheduling page, and for what the confirmation screen lets them do next.

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

  Hence the load-bearing assertion in most tests below: the organiser still
  owns exactly one meeting afterwards. The exception is the "Schedule Another
  Meeting" test, which is about the opposite failure, the reschedule context
  outliving the reschedule, and so counts two.

  `RescheduleEntryTest` covers the half of the journey before the submit:
  which day the page opens on and which meeting type it offers. Both share
  `Tymeslot.RescheduleTestSetup`.
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
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.RescheduleTestSetup
  alias Tymeslot.Workers.CalendarEventWorker

  setup :verify_on_exit!

  setup tags do
    RescheduleTestSetup.reschedule_journey(tags)
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

    # Issue #76: the reschedule notification payload didn't fit the email
    # template it was rendered by, so the send raised, the raise reached this
    # LiveView, and the booker got the theme error boundary — "Theme Error" —
    # instead of a confirmation, on a reschedule that had already succeeded.
    # Every other test here mocks the email service away, which is exactly what
    # kept the templates from ever running; this one uses the real service.
    @tag :capture_log
    test "renders the confirmation screen rather than the theme error boundary", %{
      conn: conn,
      profile: profile,
      meeting_type: meeting_type,
      meeting: meeting,
      original_start: original_start
    } do
      original_service = Application.get_env(:tymeslot, :email_service_module)
      Application.put_env(:tymeslot, :email_service_module, Tymeslot.Emails.EmailService)

      on_exit(fn ->
        Application.put_env(:tymeslot, :email_service_module, original_service)
      end)

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

      rendered = render(view)

      refute rendered =~ "Theme Error"
      assert rendered =~ ~s(data-testid="confirmation-heading")
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

  describe "\"Schedule Another Meeting\" after a reschedule" do
    # The organiser's other public type, on a schedule that opens after the
    # morning the setup meeting is moved into.
    defp afternoon_type(user, profile) do
      afternoon =
        insert(:availability_schedule,
          profile: profile,
          is_default: false,
          name: "Afternoons",
          advance_booking_days: 30,
          min_advance_hours: 0,
          buffer_minutes: 0
        )

      Enum.each(1..7, fn day_of_week ->
        insert(:weekly_availability,
          schedule: afternoon,
          day_of_week: day_of_week,
          is_available: true,
          start_time: ~T[13:00:00],
          end_time: ~T[17:00:00]
        )
      end)

      insert(:meeting_type,
        user: user,
        duration_minutes: 45,
        name: "Deep Dive",
        is_active: true,
        availability_schedule_id: afternoon.id
      )
    end

    @tag :capture_log
    test "books a new meeting instead of moving the one just rescheduled", %{
      conn: conn,
      user: user,
      profile: profile,
      meeting_type: meeting_type,
      meeting: meeting,
      original_start: original_start
    } do
      # The reschedule context used to outlive the reschedule. Nothing cleared
      # `reschedule_meeting_uid`: `handle_param_updates/2` only assigns it when
      # the param is a binary, and the confirmation step is reached in place, so
      # `handle_params/3` never ran again to drop it. The booker who took the
      # button at its word moved the meeting they had just moved, lost the time
      # they had just confirmed, and was told it had been rescheduled.
      #
      # A second public type, so that the pin lifting is observable: a
      # reschedule replaces `:meeting_types` with the one type being moved. Its
      # afternoon-only schedule keeps the second booking clear of the slot the
      # reschedule has just taken, which nothing on the page would otherwise
      # know about: the slot grid is built from the organiser's calendar, and
      # the provider is mocked here, so a meeting in the database blocks
      # nothing until its calendar event is synced.
      afternoon_type(user, profile)

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

      moved_start = Repo.get!(MeetingSchema, meeting.id).start_time

      view |> element("[data-testid='schedule-another']") |> render_click()

      cards =
        view
        |> render()
        |> Floki.parse_document!()
        |> Floki.find("[data-testid='duration-option']")

      assert length(cards) == 2,
             "the flow has restarted, so the organiser's full catalogue is the choice again"

      # Deliberately the *other* type: the second booking is a free choice, and
      # booking it proves the page is no longer pinned to the moved meeting's.
      view = walk_to_booking_form(view, profile.timezone, "deep-dive")

      view
      |> form("form[phx-submit='submit']", %{
        "booking" => %{
          "name" => "Test Attendee",
          "email" => "attendee@example.com",
          "message" => "And one more, please"
        }
      })
      |> render_submit()

      wait_until(fn -> meeting_count_for(user) == 2 end)

      kept = Repo.get!(MeetingSchema, meeting.id)

      assert DateTime.compare(kept.start_time, moved_start) == :eq,
             "the second booking must leave the rescheduled meeting where the reschedule put it"
    end
  end

  describe "a reschedule on a day at the host's booking limit" do
    # The host takes one booking a day and the booker's meeting is that day's
    # one. The submit does not count the meeting being moved against the cap,
    # so any other time that day is a valid move; the page used to count it
    # anyway, greying the whole day out and leaving the booker nothing to pick.
    @tag :capture_log
    test "offers the rest of the meeting's own day, and moving to it succeeds", %{
      conn: conn,
      user: user,
      profile: profile,
      meeting_type: meeting_type,
      meeting: meeting
    } do
      profile |> Changeset.change(%{max_bookings_per_day: 1}) |> Repo.update!()

      # The booking helper walks to tomorrow, so that is where the meeting sits.
      tomorrow = Date.add(Date.utc_today(), 1)
      original_start = DateTime.new!(tomorrow, ~T[14:00:00], "Etc/UTC")

      meeting
      |> Changeset.change(%{
        start_time: original_start,
        end_time: DateTime.add(original_start, 30, :minute)
      })
      |> Repo.update!()

      # Flunks unless tomorrow is selectable and lists at least one time.
      view =
        navigate_to_booking_form(conn, profile, meeting_type, reschedule_meeting_uid: meeting.uid)

      view
      |> form("form[phx-submit='submit']", %{
        "booking" => %{
          "name" => "Test Attendee",
          "email" => "attendee@example.com",
          "message" => "Earlier the same day suits better"
        }
      })
      |> render_submit()

      wait_until(fn ->
        Repo.get!(MeetingSchema, meeting.id).start_time != original_start
      end)

      moved = Repo.get!(MeetingSchema, meeting.id)

      assert DateTime.to_date(moved.start_time) == tomorrow
      assert DateTime.compare(moved.start_time, original_start) != :eq
      assert meeting_count_for(user) == 1
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
