defmodule TymeslotWeb.Live.Scheduling.FixedDatesBookingPageTest do
  @moduledoc """
  A fixed-date group type on its public booking page, on every shipped
  theme (`ThemeTestMatrix.all/0`; the session list is drawn by the shipped
  themes' schedule steps): the list of its planned sessions, a guest booked
  onto one chosen through it, and a closed, full or past session that
  cannot be booked.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :scheduling
  @moduletag :live

  import Ecto.Query, only: [from: 2]
  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantSchema
  alias Tymeslot.Meetings.PlannedSessions
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias TymeslotWeb.BookingDriver
  alias TymeslotWeb.ThemeTestMatrix

  # The session list is the shared `SessionList` component, the same markup
  # on every theme; the rest of the walk goes through `BookingDriver`.
  @entry "[data-testid='session-entry']"
  @date "[data-fact='date']"
  @time "[data-fact='time']"
  @attendee %{name: "Ada Guest", email: "ada@example.com", message: ""}

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    AvailabilityCache.clear_all()
    TestMocks.setup_all_mocks()

    %{user: insert(:user)}
  end

  # No availability schedule at all: a fixed-date type is offered from its
  # sessions alone.
  defp setup_page(user, theme, type_attrs \\ []) do
    profile =
      insert(:profile,
        user: user,
        username: "event-#{theme}-#{System.unique_integer([:positive])}",
        booking_theme: theme,
        timezone: "Etc/UTC"
      )

    insert(:calendar_integration, user: user, is_active: true)
    venue = insert(:venue, user: user, name: "Main Hall")

    meeting_type =
      insert(
        :meeting_type,
        Keyword.merge(
          [
            user: user,
            name: "Introduction to X",
            duration_minutes: 90,
            is_active: true,
            max_participants: 20,
            fixed_dates: true,
            locations: [in_person_location([venue])]
          ],
          type_attrs
        )
      )

    {profile, meeting_type}
  end

  defp in_days(days, time),
    do: Date.utc_today() |> Date.add(days) |> DateTime.new!(time, "Etc/UTC")

  defp open(profile),
    do: live(build_conn(), "/#{profile.username}/introduction-to-x?timezone=Etc/UTC")

  defp age(session, field, value) do
    Repo.update_all(
      from(m in MeetingSchema, where: m.id == ^session.id),
      set: [{field, value}]
    )

    AvailabilityCache.clear_all()
  end

  for %{id: theme, name: name} <- ThemeTestMatrix.all() do
    describe name do
      @tag :capture_log
      test "lists the sessions with their seats and registration close", %{user: user} do
        {profile, meeting_type} = setup_page(user, unquote(theme))
        starts_at = in_days(3, ~T[18:00:00])

        {:ok, _session} =
          PlannedSessions.add(meeting_type, meeting_type.user_id, starts_at,
            registration_closes_at: DateTime.add(starts_at, -86_400)
          )

        {:ok, view, _html} = open(profile)

        wait_until(fn -> has_element?(view, @entry) end)

        html = render(view)
        assert html =~ "Dates"
        # The type's spots display, here its default traffic light.
        assert has_element?(view, "#{@entry} [data-testid='seat-badge']", "Plenty left")
        assert has_element?(view, @entry, "Registration until")
      end

      @tag :capture_log
      test "books a guest onto a planned session chosen from the list", %{user: user} do
        {profile, meeting_type} =
          setup_page(user, unquote(theme), max_participants: 3, last_spots_threshold: 5)

        starts_at = in_days(3, ~T[18:00:00])
        {:ok, session} = PlannedSessions.add(meeting_type, meeting_type.user_id, starts_at)

        {:ok, view, _html} = open(profile)
        wait_until(fn -> has_element?(view, @entry) end)
        assert has_element?(view, @entry, "3 spots left")

        view |> element(@entry) |> render_click()
        BookingDriver.pick_time(view, "6:00 PM")
        BookingDriver.continue(view)
        BookingDriver.submit(view, @attendee)

        wait_until(fn -> has_element?(view, "[data-intent='restart']") end)

        # The booking joined the host's session rather than making a meeting of its own.
        assert [%{email: "ada@example.com", name: "Ada Guest"}] = live_participants(session)
        assert PlannedSessions.participant_count(session) == 1
        assert [%{id: id}] = PlannedSessions.list(meeting_type)
        assert id == session.id

        AvailabilityCache.clear_all()
        {:ok, view, _html} = open(profile)
        wait_until(fn -> has_element?(view, @entry) end)
        assert has_element?(view, @entry, "2 spots left")
      end

      @tag :capture_log
      test "a session whose registration has closed cannot be booked", %{user: user} do
        {profile, meeting_type} = setup_page(user, unquote(theme))

        {:ok, session} =
          PlannedSessions.add(meeting_type, meeting_type.user_id, in_days(3, ~T[18:00:00]))

        age(session, :registration_closes_at, DateTime.add(DateTime.utc_now(), -60, :second))

        {:ok, view, _html} = open(profile)

        wait_until(fn -> has_element?(view, @entry) end)
        assert has_element?(view, "#{@entry}[disabled]")
        assert has_element?(view, "[data-testid='sessions-closed']", "Registration is closed.")
        assert_nothing_to_book(view)
      end

      @tag :capture_log
      test "a full session cannot be booked", %{user: user} do
        {profile, meeting_type} = setup_page(user, unquote(theme), max_participants: 2)

        {:ok, session} =
          PlannedSessions.add(meeting_type, meeting_type.user_id, in_days(3, ~T[18:00:00]))

        meeting = Repo.get!(MeetingSchema, session.id)
        insert_list(2, :participant, meeting: meeting)

        {:ok, view, _html} = open(profile)

        wait_until(fn -> has_element?(view, @entry) end)
        assert has_element?(view, "#{@entry}[disabled]")
        # Registration is still open: the date is full, not closed.
        assert has_element?(view, "[data-testid='sessions-full']", "All dates are fully booked.")
        refute render(view) =~ "Registration is closed."
        assert_nothing_to_book(view)
      end

      @tag :capture_log
      test "a session in a later month takes the calendar to that month", %{user: user} do
        {profile, meeting_type} = setup_page(user, unquote(theme))

        # 32 days apart, so always in different months.
        for days <- [3, 35] do
          {:ok, _session} =
            PlannedSessions.add(meeting_type, meeting_type.user_id, in_days(days, ~T[18:00:00]))
        end

        later = Date.utc_today() |> Date.add(35) |> Date.to_iso8601()

        {:ok, view, _html} = open(profile)
        wait_until(fn -> has_element?(view, "#{@entry}[phx-value-date='#{later}']") end)
        refute has_element?(view, "#{@date}[data-value='#{later}']")

        view |> element("#{@entry}[phx-value-date='#{later}']") |> render_click()

        wait_until(fn -> has_element?(view, "#{@date}[data-value='#{later}']") end)
        # The day's own time is offered, so the booking carries on from there.
        BookingDriver.pick_time(view, "6:00 PM")
      end

      @tag :capture_log
      test "says the event has ended once its sessions are over", %{user: user} do
        {profile, meeting_type} = setup_page(user, unquote(theme))

        {:ok, session} =
          PlannedSessions.add(meeting_type, meeting_type.user_id, in_days(3, ~T[18:00:00]))

        past = DateTime.add(DateTime.utc_now(), -86_400, :second)
        age(session, :start_time, past)
        age(session, :end_time, DateTime.add(past, 90, :minute))

        {:ok, view, _html} = open(profile)

        wait_until(fn -> has_element?(view, "[data-testid='sessions-none']") end)
        assert render(view) =~ "This event has ended."
        refute has_element?(view, @date)
      end
    end
  end

  defp live_participants(session) do
    Repo.all(
      from(p in ParticipantSchema, where: p.meeting_id == ^session.id and is_nil(p.cancelled_at))
    )
  end

  # Nothing on the page lets the visitor reach a time: the session cannot be
  # chosen, the calendar is not drawn, and no time or booking form is offered.
  defp assert_nothing_to_book(view) do
    refute has_element?(view, "#{@entry}:not([disabled])")
    refute has_element?(view, "#{@entry} [data-testid='seat-badge']")
    refute has_element?(view, @date)
    refute has_element?(view, @time)
    refute has_element?(view, "form[data-fact='attendee']")
  end

  describe "the organiser's page" do
    @tag :capture_log
    test "leaves out a fixed-date type nobody can sign up for", %{user: user} do
      {profile, meeting_type} = setup_page(user, "2")
      insert(:meeting_type, user: user, name: "Solo Call", duration_minutes: 30, is_active: true)

      {:ok, _view, html} = live(build_conn(), "/#{profile.username}?timezone=Etc/UTC")
      refute html =~ "Introduction to X"
      assert html =~ "Solo Call"

      {:ok, _session} =
        PlannedSessions.add(meeting_type, meeting_type.user_id, in_days(3, ~T[18:00:00]))

      {:ok, _view, html} = live(build_conn(), "/#{profile.username}?timezone=Etc/UTC")
      assert html =~ "Introduction to X"
    end
  end
end
