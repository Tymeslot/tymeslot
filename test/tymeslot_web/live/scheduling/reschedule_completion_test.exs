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
        timezone: timezone
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

  describe "the day a reschedule opens on" do
    @tag :capture_log
    test "the schedule step opens on a bookable day with its times listed", %{
      conn: conn,
      profile: profile,
      meeting: meeting
    } do
      # The auto-selection used to stand down for the whole reschedule journey:
      # it treated `is_rescheduling` as a deliberate choice of day, on the
      # belief that a reschedule link carried a date. It carries only the uid,
      # so nothing was being preserved — the rescheduler simply got the empty
      # grid, and does so against the calendar that was full enough to force
      # the move in the first place.
      #
      # This walks the real entry rather than setting the assign, because the
      # two disagree on ordering: `do_handle_schedule_entry/2` runs before
      # `handle_params/3` on the connected mount, so `is_rescheduling` is not
      # yet on the socket at the moment a synchronous fetch resolves. A unit
      # test on the assign cannot see that; this does.
      {:ok, view, _html} =
        live(
          conn,
          "/#{profile.username}?timezone=#{profile.timezone}&reschedule_meeting_uid=#{meeting.uid}"
        )

      view |> element("button[data-testid='duration-option']") |> render_click()
      view |> element("button[data-testid='next-step']") |> render_click()

      wait_until(fn -> has_element?(view, "button.time-slot-button") end)

      state = :sys.get_state(view.pid).socket.assigns

      assert state.is_rescheduling,
             "the reschedule context must survive the step transition, or this proves nothing"

      assert {:ok, %Date{}} = Date.from_iso8601(state.selected_date)

      document = view |> render() |> Floki.parse_document!()

      assert Floki.find(document, "button.calendar-day--selected") != [],
             "expected the reschedule to open on a day painted as selected"

      assert Floki.attribute(document, "button.time-slot-button", "phx-value-time") != [],
             "expected that day's times to be listed"

      # The hour stays the rescheduler's decision, exactly as for a new booking.
      assert state.selected_time == nil
    end
  end

  describe "the schedule a reschedule is offered against" do
    # A second, unrelated type the organiser also offers publicly. Without one
    # the "exactly one card" assertions below pass on an empty catalogue and
    # prove nothing, since `setup` inserts a single meeting type.
    defp second_public_type(user) do
      insert(:meeting_type,
        user: user,
        duration_minutes: 45,
        name: "Deep Dive",
        is_active: true
      )
    end

    # Moves the meeting onto a type of its own, on a schedule with a window
    # nothing else uses, so "which type is this page on?" is answerable from
    # `booking_window_days` alone.
    defp pin_meeting_to_its_own_type(user, profile, meeting) do
      long_schedule =
        insert(:availability_schedule,
          profile: profile,
          is_default: false,
          name: "Long lead time",
          advance_booking_days: 180,
          min_advance_hours: 0,
          buffer_minutes: 0
        )

      pinned_type =
        insert(:meeting_type,
          user: user,
          duration_minutes: 30,
          name: "Pinned Chat",
          is_active: true,
          availability_schedule_id: long_schedule.id
        )

      {:ok, _updated} =
        meeting
        |> Changeset.change(%{meeting_type_id: pinned_type.id})
        |> Repo.update()

      pinned_type
    end

    @tag :capture_log
    test "comes from the meeting's own type, not a duration match", %{
      conn: conn,
      user: user,
      profile: profile,
      meeting: meeting
    } do
      # A reschedule link carries only the meeting uid, and the type used to be
      # re-picked from the duration in the URL — which resolves against slugs,
      # so it matched nothing and the page fell back to the profile's default
      # schedule. Slots were then offered from the default while the submit was
      # validated against the meeting's own type, which is the one way left to
      # break "if it is offered, it can be booked".
      pinned_type = pin_meeting_to_its_own_type(user, profile, meeting)

      {:ok, view, _html} =
        live(conn, "/#{profile.username}?timezone=UTC&reschedule_meeting_uid=#{meeting.uid}")

      # The other type is not offered at all any more: a reschedule shows the
      # meeting's own type and nothing else.
      refute has_element?(
               view,
               "button[data-testid='duration-option'][phx-value-duration='quick-chat']"
             )

      # The card is gone, but the event behind it is still the client's to
      # push, so the server is what has to hold. The only card on the page is
      # clicked with another type's slug overriding its value — the closest a
      # test gets to a crafted client without bypassing the component.
      view
      |> element("button[data-testid='duration-option']")
      |> render_click(%{"duration" => "quick-chat"})

      render(view)
      assigns = :sys.get_state(view.pid).socket.assigns

      assert assigns.meeting_type.id == pinned_type.id
      assert assigns.booking_window_days == 180

      # The slug is discarded rather than kept alongside the pinned type: left
      # on "quick-chat" it is no longer one of `:meeting_types`, and the step's
      # own validation then refuses to advance with no card showing why.
      assert assigns.selected_duration == "pinned-chat"
      assert assigns.duration == "pinned-chat"
    end

    @tag :capture_log
    test "a stale slug in the URL does not move the reschedule off its type", %{
      conn: conn,
      user: user,
      profile: profile,
      meeting: meeting
    } do
      # `/:username/:slug` resolves the type from the slug, and a reschedule
      # reaches it through a mid-flow locale switch or an old direct booking
      # link with the uid appended. Resolved by slug, the page offered slots
      # against "Quick Chat"'s 30-day window while the submit validated against
      # the meeting's own 180-day one.
      pinned_type = pin_meeting_to_its_own_type(user, profile, meeting)

      {:ok, view, _html} =
        live(
          conn,
          "/#{profile.username}/quick-chat?timezone=UTC&reschedule_meeting_uid=#{meeting.uid}"
        )

      assigns = :sys.get_state(view.pid).socket.assigns

      assert assigns.meeting_type.id == pinned_type.id
      assert assigns.booking_window_days == 180
      assert assigns.selected_duration == "pinned-chat"
      assert assigns.duration == "pinned-chat"
    end

    @tag :capture_log
    test "offers the meeting's own type, already selected", %{
      conn: conn,
      user: user,
      profile: profile,
      meeting: meeting
    } do
      second_public_type(user)

      {:ok, view, _html} =
        live(conn, "/#{profile.username}?timezone=UTC&reschedule_meeting_uid=#{meeting.uid}")

      # One card out of the two the organiser offers, and it is the meeting's
      # own: a reschedule is not a choice of meeting type, so the step confirms
      # what is being moved rather than asking for something that cannot be
      # changed.
      cards =
        view
        |> render()
        |> Floki.parse_document!()
        |> Floki.find("[data-testid='duration-option']")

      assert length(cards) == 1
      assert Floki.attribute(cards, "phx-value-duration") == ["quick-chat"]

      # Already selected, so "next" is one click rather than a forced pick.
      assert has_element?(view, "[data-testid='duration-option'].duration-card--selected")
      refute has_element?(view, "[data-testid='next-step'][disabled]")
    end

    @tag :capture_log
    test "offers the meeting's own type already selected in Rhythm too", %{
      conn: conn,
      user: user,
      profile: profile,
      meeting: meeting
    } do
      # Rhythm marks the selection on the card's wrapper rather than on the
      # button carrying the testid, so the Quill assertion above matches
      # nothing here and would pass on a page that pinned nothing.
      second_public_type(user)
      {:ok, profile} = profile |> Changeset.change(%{booking_theme: "2"}) |> Repo.update()

      {:ok, view, _html} =
        live(conn, "/#{profile.username}?timezone=UTC&reschedule_meeting_uid=#{meeting.uid}")

      cards =
        view
        |> render()
        |> Floki.parse_document!()
        |> Floki.find("[data-testid='duration-option']")

      assert length(cards) == 1
      assert Floki.attribute(cards, "phx-value-duration") == ["quick-chat"]

      assert has_element?(view, ".duration-card.selected [data-testid='duration-option']")
      refute has_element?(view, "[data-testid='next-step'][disabled]")
    end

    @tag :capture_log
    test "clicking the pinned card in Rhythm does not deselect it", %{
      conn: conn,
      profile: profile,
      meeting: meeting
    } do
      # Rhythm deselects the selected card when it is clicked again, which is
      # how a booker changes their mind there. On a pinned reschedule that
      # would disable "next" over a choice that was never theirs and leave
      # them stuck on the step, so the selection has to survive the click.
      {:ok, profile} = profile |> Changeset.change(%{booking_theme: "2"}) |> Repo.update()

      {:ok, view, _html} =
        live(conn, "/#{profile.username}?timezone=UTC&reschedule_meeting_uid=#{meeting.uid}")

      # Anchored first: without this the refute below passes just as well on a
      # page that never pinned anything, where the click selects a card.
      assert has_element?(view, ".duration-card.selected [data-testid='duration-option']")

      view |> element("[data-testid='duration-option']") |> render_click()
      render(view)

      assert has_element?(view, ".duration-card.selected [data-testid='duration-option']")
      refute has_element?(view, "[data-testid='next-step'][disabled]")
    end
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
