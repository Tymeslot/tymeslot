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

  The untested middle is where the bug lives. `LiveHelpers.Mount` turns that
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
  alias TymeslotWeb.BookingDriver

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
    # LiveView, and the booker got the theme error boundary (its error card)
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

      refute rendered =~ "theme-error-title"
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
    # The organiser's other public type, on the same default schedule as the
    # first. It needs no window of its own: the reschedule has taken one of
    # that schedule's slots, the page no longer offers it, and the walk below
    # simply lands on the next one.
    defp second_type(user) do
      insert(:meeting_type,
        user: user,
        duration_minutes: 45,
        name: "Deep Dive",
        is_active: true
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
      # reschedule replaces `:meeting_types` with the one type being moved.
      second_type(user)

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

      # The day and time just booked belong to the finished booking. Kept, the
      # schedule step would open the next booking's calendar on them.
      assert %{selected_date: nil, selected_time: nil} =
               :sys.get_state(view.pid).socket.assigns

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

  describe "a booking whose meeting type has since been deleted" do
    # Deliberately not refused, unlike a seat whose type is gone: a whole
    # booking with no type moves like an ad-hoc one, on the type its length
    # matches (`Reschedule`), so the page offers the organiser's types as a
    # real choice rather than pinning one.
    @tag :capture_log
    test "is offered the organiser's types, and moves", %{
      conn: conn,
      user: user,
      profile: profile,
      meeting_type: meeting_type,
      meeting: meeting,
      original_start: original_start
    } do
      replacement =
        insert(:meeting_type, user: user, duration_minutes: 30, name: "New Chat", is_active: true)

      Repo.delete!(meeting_type)

      view =
        navigate_to_booking_form(conn, profile, replacement, reschedule_meeting_uid: meeting.uid)

      refute :sys.get_state(view.pid).socket.assigns.meeting_type_pinned

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

      assert meeting_count_for(user) == 1
    end
  end

  describe "a booking cancelled while its reschedule page is open" do
    # The page checks the meeting when it applies its URL; nothing re-checks
    # it as the booker moves from step to step. Whatever the page has kept of
    # the meeting meanwhile, the submit asks the rules again, and a booking
    # cancelled in between is refused there, with the reason.
    @tag :capture_log
    test "the submit is refused with the reason, and the meeting is not moved", %{
      conn: conn,
      user: user,
      profile: profile,
      meeting_type: meeting_type,
      meeting: meeting,
      original_start: original_start
    } do
      view =
        navigate_to_booking_form(conn, profile, meeting_type, reschedule_meeting_uid: meeting.uid)

      meeting |> Changeset.change(%{status: "cancelled"}) |> Repo.update!()

      view
      |> form("form[phx-submit='submit']", %{
        "booking" => %{
          "name" => "Test Attendee",
          "email" => "attendee@example.com",
          "message" => ""
        }
      })
      |> render_submit()

      wait_until(fn -> render(view) =~ "Cannot reschedule a cancelled meeting" end)

      kept = Repo.get!(MeetingSchema, meeting.id)
      assert kept.status == "cancelled"
      assert DateTime.compare(kept.start_time, original_start) == :eq
      assert meeting_count_for(user) == 1
    end

    # Applying the URL again (a patch, back and forward in the browser) asks
    # the rules afresh, as arriving does, rather than trusting what the page
    # learnt about the meeting when it opened.
    @tag :capture_log
    test "applying the page's URL again refuses it, as arriving would", %{
      conn: conn,
      profile: profile,
      meeting: meeting
    } do
      path = "/#{profile.username}?timezone=UTC&reschedule_meeting_uid=#{meeting.uid}"
      {:ok, view, _html} = live(conn, path)

      meeting |> Changeset.change(%{status: "cancelled"}) |> Repo.update!()

      assert {:error, {:live_redirect, %{to: to}}} = render_patch(view, path)
      assert to == "/#{profile.username}?timezone=UTC"
      assert assert_redirect(view, to)["error"] == "Cannot reschedule a cancelled meeting"
    end
  end

  describe "a URL that no longer names the reschedule" do
    # The URL decides whether the page is a reschedule (`is_rescheduling` is
    # read from it), so the booking it names has to follow it too. Kept from
    # an earlier URL (browser history across "Schedule another meeting"), it
    # left a fresh booking pinned to the old meeting's type and prefilled
    # with its attendee's details.
    @tag :capture_log
    test "leaves the reschedule behind", %{
      conn: conn,
      user: user,
      profile: profile,
      meeting: meeting
    } do
      insert(:meeting_type, user: user, duration_minutes: 45, name: "Deep Dive", is_active: true)

      {:ok, view, _html} =
        live(conn, "/#{profile.username}?timezone=UTC&reschedule_meeting_uid=#{meeting.uid}")

      render_patch(view, "/#{profile.username}?timezone=UTC")

      # The pin had narrowed the overview to the meeting's own type.
      assert Enum.sort(BookingDriver.meeting_types(view)) == ["deep-dive", "quick-chat"]

      view = walk_to_booking_form(view, "UTC", "quick-chat")

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.reschedule_meeting_uid == nil
      assert assigns.reschedule_context == nil
      refute render(view) =~ ~s(value="Test Attendee")
    end

    # The pin had made the meeting's own type the selection; once it is gone
    # from the catalogue the overview offers, no card matches it, and "next"
    # would book a type the page no longer shows.
    @tag :capture_log
    test "drops the meeting's type from the selection when the overview no longer offers it", %{
      conn: conn,
      user: user,
      profile: profile,
      meeting_type: meeting_type,
      meeting: meeting
    } do
      insert(:meeting_type, user: user, duration_minutes: 45, name: "Deep Dive", is_active: true)

      {:ok, view, _html} =
        live(conn, "/#{profile.username}?timezone=UTC&reschedule_meeting_uid=#{meeting.uid}")

      assert :sys.get_state(view.pid).socket.assigns.selected_duration == "quick-chat"

      meeting_type |> Changeset.change(%{is_active: false}) |> Repo.update!()
      render_patch(view, "/#{profile.username}?timezone=UTC")

      assert BookingDriver.meeting_types(view) == ["deep-dive"]

      assigns = :sys.get_state(view.pid).socket.assigns
      assert assigns.selected_duration == nil
      assert assigns.meeting_type == nil
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
