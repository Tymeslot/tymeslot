defmodule TymeslotWeb.Live.Themes.MultipleLengthsFlowTest do
  @moduledoc """
  A meeting type can offer several lengths. The booker then picks one in a
  step of its own, between the meeting type and the calendar, in both themes;
  a type with one length never shows that step.
  """

  use TymeslotWeb.LiveCase, async: false
  @moduletag :scheduling

  import Ecto.Query, only: [from: 2]
  import Mox
  import Phoenix.LiveViewTest
  import Tymeslot.BookingTestHelpers, only: [seed_booking_account: 3]
  import Tymeslot.Factory
  import Tymeslot.TestHelpers.Eventually

  alias Tymeslot.Availability.WeeklyAvailabilitySchema
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias TymeslotWeb.BookingDriver

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    AvailabilityCache.clear_all()
    TestMocks.setup_email_mocks()
    TestMocks.setup_subscription_mocks()

    Tymeslot.CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start_date, _end_date -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _user_id -> {:error, :no_integration} end)

    :ok
  end

  # Gives the seeded 30-minute "Quick Chat" two further lengths.
  defp seed_several_lengths(theme_id, username) do
    %{user: user, profile: profile} = seed_booking_account(theme_id, username, "UTC")

    Repo.update_all(
      from(mt in MeetingTypeSchema, where: mt.user_id == ^user.id),
      set: [extra_lengths_minutes: [60, 15]]
    )

    %{user: user, profile: profile}
  end

  # A booking of the longer length, on a type whose primary length is shorter:
  # whatever grid the reschedule is offered must be the booked one.
  defp booked_hour(user) do
    meeting_type = Repo.get_by!(MeetingTypeSchema, user_id: user.id)
    start = DateTime.utc_now() |> DateTime.add(7, :day) |> DateTime.truncate(:second)

    insert(:meeting,
      organizer_user_id: user.id,
      meeting_type_id: meeting_type.id,
      attendee_email: "resched@example.com",
      attendee_timezone: "UTC",
      start_time: start,
      end_time: DateTime.add(start, 60, :minute),
      duration: 60,
      status: "confirmed"
    )
  end

  defp length_options(view) do
    view
    |> render()
    |> Floki.parse_document!()
    |> Floki.attribute("button[data-testid='length-option']", "data-minutes")
  end

  defp time_values(view) do
    view
    |> render()
    |> Floki.parse_document!()
    |> Floki.attribute("[data-fact='time']:not([disabled])", "data-value")
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp pick_first_slot_and_continue(view) do
    BookingDriver.pick_first_slot(view)
    BookingDriver.continue(view)
    eventually(fn -> has_element?(view, "form[data-testid='booking-form']") end, timeout: 5000)
  end

  for {theme_id, theme} <- [{"1", "quill"}, {"2", "rhythm"}] do
    describe "#{theme}" do
      @tag :capture_log
      test "asks for the length after the meeting type and books the one chosen",
           %{conn: conn} do
        %{user: user, profile: profile} =
          seed_several_lengths(unquote(theme_id), "lengths-#{unquote(theme)}")

        {:ok, view, html} = live(conn, ~p"/#{profile.username}")

        # The overview card shows the span rather than one length.
        assert html =~ "15–60 min"

        view
        |> element("button[data-testid='duration-option'][data-duration='quick-chat']")
        |> render_click()

        view |> element("button[data-testid='next-step']") |> render_click()

        assert has_element?(view, "[data-testid='length-step']")
        assert length_options(view) == ["15", "30", "60"]
        assert has_element?(view, "button[data-testid='next-step'][disabled]")

        view
        |> element("button[data-testid='length-option'][data-minutes='60']")
        |> render_click()

        view |> element("button[data-testid='next-step']") |> render_click()
        refute has_element?(view, "[data-testid='length-step']")

        pick_first_slot_and_continue(view)
        assert render(view) =~ "1 hour"

        BookingDriver.submit(view, %{
          name: "Test Attendee",
          email: "lengths-#{unquote(theme)}@example.com"
        })

        eventually(fn -> has_element?(view, "[data-testid='confirmation-heading']") end,
          timeout: 10_000
        )

        meeting = Repo.get_by!(MeetingSchema, organizer_user_id: user.id)
        assert meeting.duration == 60
        assert DateTime.diff(meeting.end_time, meeting.start_time, :minute) == 60
      end

      # Back from the calendar to change the length: the time picked for the
      # first length goes, the calendar offers the second length's times
      # (`Facts.Slot.enter/2` refreshing the stale slot snapshot), and the
      # booking is stored for the second length.
      @tag :capture_log
      test "changing the length after picking a time offers and books the new length",
           %{conn: conn} do
        %{user: user, profile: profile} =
          seed_several_lengths(unquote(theme_id), "relength-#{unquote(theme)}")

        {:ok, view, _html} = live(conn, ~p"/#{profile.username}")
        day = Date.utc_today() |> Date.add(2) |> Date.to_iso8601()

        BookingDriver.choose_meeting_type(view, "quick-chat")
        BookingDriver.continue(view)
        BookingDriver.choose_length(view, 15)
        BookingDriver.continue(view)

        # On a 15-minute grid a quarter past is offered; it does not fit the
        # hourly grid of 60 minutes.
        BookingDriver.pick_first_slot(view, on: day)
        fifteen_times = time_values(view)
        [_on_the_hour, quarter_past | _rest] = fifteen_times
        BookingDriver.pick_time(view, quarter_past)
        assert assigns(view).selected_time == quarter_past

        BookingDriver.back(view)
        assert has_element?(view, "[data-testid='length-step']")
        BookingDriver.choose_length(view, 60)
        BookingDriver.continue(view)
        BookingDriver.load(view)

        eventually(fn -> time_values(view) != [] end, timeout: 5000)
        hour_times = time_values(view)

        refute quarter_past in hour_times
        assert length(hour_times) < length(fifteen_times)
        assert assigns(view).duration_minutes == 60
        assert assigns(view).selected_date == day
        assert assigns(view).selected_time == nil

        [first_hour | _rest] = hour_times
        BookingDriver.pick_time(view, first_hour)
        BookingDriver.continue(view)
        eventually(fn -> has_element?(view, "form[data-fact='attendee']") end, timeout: 5000)

        BookingDriver.submit(view, %{
          name: "Test Attendee",
          email: "relength-#{unquote(theme)}@example.com"
        })

        eventually(fn -> has_element?(view, "[data-intent='restart']") end, timeout: 10_000)

        meeting = Repo.get_by!(MeetingSchema, organizer_user_id: user.id)
        assert meeting.duration == 60
        assert DateTime.diff(meeting.end_time, meeting.start_time, :minute) == 60
      end

      # Open 16:00 to 17:00 UTC only, seen from Bangkok (UTC+7): the one hour
      # is 23:00 to 00:00 there. Booked for 60 minutes, the 23:00 slot ends the
      # next day; for the type's own 30 it would not, so the note must follow
      # the length chosen.
      @tag :capture_log
      test "the booking step notes the next-day end of the length chosen", %{conn: conn} do
        %{profile: profile} = seed_several_lengths(unquote(theme_id), "late-#{unquote(theme)}")

        Repo.update_all(
          from(w in WeeklyAvailabilitySchema,
            join: s in assoc(w, :schedule),
            where: s.profile_id == ^profile.id
          ),
          set: [start_time: ~T[16:00:00]]
        )

        {:ok, view, _html} =
          live(conn, ~p"/#{profile.username}/quick-chat?minutes=60&timezone=Asia/Bangkok")

        day = Date.utc_today() |> Date.add(2) |> Date.to_iso8601()
        assert {^day, "11:00 PM"} = BookingDriver.pick_first_slot(view, on: day)
        BookingDriver.continue(view)
        eventually(fn -> has_element?(view, "form[data-fact='attendee']") end, timeout: 5000)

        next_day = Date.utc_today() |> Date.add(3) |> Calendar.strftime("%A %-d %B")

        assert view |> element("[data-testid='booking-next-day-end']") |> render() =~
                 "Ends 12:00 AM on #{next_day}"
      end

      # The shared walk every flow suite books through takes the length too,
      # through the markup contract alone.
      @tag :capture_log
      test "the shared booking walk books the length asked for", %{conn: conn} do
        %{user: user, profile: profile} =
          seed_several_lengths(unquote(theme_id), "walk-#{unquote(theme)}")

        {:ok, view, _html} = live(conn, ~p"/#{profile.username}")
        BookingDriver.book(view, meeting_type: "quick-chat", length: 15)

        meeting = Repo.get_by!(MeetingSchema, organizer_user_id: user.id)
        assert meeting.duration == 15
        assert DateTime.diff(meeting.end_time, meeting.start_time, :minute) == 15
      end

      test "a direct link to the type opens on the length choice", %{conn: conn} do
        %{profile: profile} = seed_several_lengths(unquote(theme_id), "direct-#{unquote(theme)}")

        {:ok, view, _html} = live(conn, ~p"/#{profile.username}/quick-chat")

        assert has_element?(view, "[data-testid='length-step']")
        assert length_options(view) == ["15", "30", "60"]
      end

      test "a link naming an offered length skips the choice", %{conn: conn} do
        %{profile: profile} = seed_several_lengths(unquote(theme_id), "preset-#{unquote(theme)}")

        {:ok, view, _html} = live(conn, ~p"/#{profile.username}/quick-chat?minutes=60")

        refute has_element?(view, "[data-testid='length-step']")
        assert render(view) =~ "1 hour"
      end

      test "a link naming a length the type does not offer still asks", %{conn: conn} do
        %{profile: profile} = seed_several_lengths(unquote(theme_id), "bogus-#{unquote(theme)}")

        {:ok, view, _html} = live(conn, ~p"/#{profile.username}/quick-chat?minutes=45")

        assert has_element?(view, "[data-testid='length-step']")
      end

      test "the calendar leads back to the length choice", %{conn: conn} do
        %{profile: profile} = seed_several_lengths(unquote(theme_id), "back-#{unquote(theme)}")

        {:ok, view, _html} = live(conn, ~p"/#{profile.username}/quick-chat?minutes=60")

        view |> element("[data-testid='back-step']") |> render_click()

        assert has_element?(view, "[data-testid='length-step']")
        # The length chosen before is still selected.
        assert has_element?(view, "button[data-testid='length-option'][aria-pressed='true']")
      end

      test "a type with one length never shows the step", %{conn: conn} do
        %{profile: profile} =
          seed_booking_account(unquote(theme_id), "single-#{unquote(theme)}", "UTC")

        {:ok, view, _html} = live(conn, ~p"/#{profile.username}")

        view
        |> element("button[data-testid='duration-option'][data-duration='quick-chat']")
        |> render_click()

        view |> element("button[data-testid='next-step']") |> render_click()

        refute has_element?(view, "[data-testid='length-step']")
      end

      test "a reschedule keeps the booked length and skips the choice", %{conn: conn} do
        %{user: user, profile: profile} =
          seed_several_lengths(unquote(theme_id), "resched-#{unquote(theme)}")

        meeting_type = Repo.get_by!(MeetingTypeSchema, user_id: user.id)
        start = DateTime.utc_now() |> DateTime.add(7, :day) |> DateTime.truncate(:second)

        meeting =
          insert(:meeting,
            organizer_user_id: user.id,
            meeting_type_id: meeting_type.id,
            attendee_email: "resched@example.com",
            attendee_timezone: "UTC",
            start_time: start,
            end_time: DateTime.add(start, 60, :minute),
            duration: 60,
            status: "confirmed"
          )

        {:ok, view, _html} =
          live(conn, ~p"/#{profile.username}?reschedule_meeting_uid=#{meeting.uid}")

        view
        |> element("button[data-testid='duration-option'][data-duration='quick-chat']")
        |> render_click()

        view |> element("button[data-testid='next-step']") |> render_click()

        refute has_element?(view, "[data-testid='length-step']")
        assert render(view) =~ "1 hour"
      end

      # `/:username/:slug` is where a locale switch mid-reschedule and an old
      # direct link with the uid appended both land. The type is resolved in
      # `mount` there, before `handle_params` has read the uid, so this is the
      # route on which a reschedule would otherwise be taken for a fresh
      # booking: asked for a length, or offered the primary one's grid.
      test "a reschedule entering at the type's own page keeps the booked length",
           %{conn: conn} do
        %{user: user, profile: profile} =
          seed_several_lengths(unquote(theme_id), "resched-slug-#{unquote(theme)}")

        meeting = booked_hour(user)

        {:ok, view, _html} =
          live(conn, ~p"/#{profile.username}/quick-chat?reschedule_meeting_uid=#{meeting.uid}")

        refute has_element?(view, "[data-testid='length-step']")
        assert render(view) =~ "1 hour"
      end

      test "a reschedule entering at the booking form keeps the booked length", %{conn: conn} do
        %{user: user, profile: profile} =
          seed_several_lengths(unquote(theme_id), "resched-book-#{unquote(theme)}")

        meeting = booked_hour(user)

        {:ok, view, _html} =
          live(
            conn,
            ~p"/#{profile.username}/quick-chat/book?reschedule_meeting_uid=#{meeting.uid}"
          )

        refute has_element?(view, "[data-testid='length-step']")
        assert render(view) =~ "1 hour"
      end
    end
  end

  describe "quill's step indicator" do
    # The length choice is a step of the journey of its own but sits under
    # "Duration" in the indicator, so "Date & Time" has to send the calendar's
    # number rather than its own position.
    @tag :capture_log
    test "Date & Time leads back to the calendar, past the length choice", %{conn: conn} do
      %{profile: profile} = seed_several_lengths("1", "indicator-quill")

      {:ok, view, _html} = live(conn, ~p"/#{profile.username}/quick-chat?minutes=60")

      pick_first_slot_and_continue(view)

      view |> element("button[phx-click='navigate_to_step']", "Date & Time") |> render_click()

      refute has_element?(view, "form[data-testid='booking-form']")
      refute has_element?(view, "[data-testid='length-step']")
      assert has_element?(view, "[data-testid='schedule-actions']")
    end
  end
end
