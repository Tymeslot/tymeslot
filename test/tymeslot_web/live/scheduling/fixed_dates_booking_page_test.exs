defmodule TymeslotWeb.Live.Scheduling.FixedDatesBookingPageTest do
  @moduledoc """
  A fixed-date group type on its public booking page, in both themes: the
  list of its planned sessions, choosing one through it, and what the page
  says once nothing can be booked any more.
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
  alias Tymeslot.Meetings.PlannedSessions
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  @time_slot "button[data-testid='time-slot']"
  @next_step "button[data-testid='next-step']"

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    AvailabilityCache.clear_all()
    TestMocks.setup_all_mocks()

    %{user: insert(:user)}
  end

  # No availability schedule at all: a fixed-date type is offered from its
  # sessions alone.
  defp setup_page(user, theme) do
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
      insert(:meeting_type,
        user: user,
        name: "Introduction to X",
        duration_minutes: 90,
        is_active: true,
        max_participants: 20,
        fixed_dates: true,
        locations: [in_person_location([venue])]
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

  for {theme, name} <- [{"1", "Quill"}, {"2", "Rhythm"}] do
    describe name do
      @tag :capture_log
      test "lists the sessions and books one through the list", %{user: user} do
        {profile, meeting_type} = setup_page(user, unquote(theme))
        starts_at = in_days(3, ~T[18:00:00])

        {:ok, _session} =
          PlannedSessions.add(meeting_type, starts_at,
            registration_closes_at: DateTime.add(starts_at, -86_400)
          )

        {:ok, view, _html} = open(profile)

        wait_until(fn -> has_element?(view, "[data-testid='session-entry']") end)

        html = render(view)
        assert html =~ "Dates"
        assert html =~ "20 seats left"
        assert html =~ "Registration until"

        view |> element("[data-testid='session-entry']") |> render_click()

        wait_until(fn -> has_element?(view, "#{@time_slot}[phx-value-time='6:00 PM']") end)
        view |> element("#{@time_slot}[phx-value-time='6:00 PM']") |> render_click()
        view |> element(@next_step) |> render_click()

        wait_until(fn -> has_element?(view, "input[name='booking[email]']") end)
      end

      @tag :capture_log
      test "says registration is closed, and shows no calendar", %{user: user} do
        {profile, meeting_type} = setup_page(user, unquote(theme))
        {:ok, session} = PlannedSessions.add(meeting_type, in_days(3, ~T[18:00:00]))
        age(session, :registration_closes_at, DateTime.add(DateTime.utc_now(), -60, :second))

        {:ok, view, _html} = open(profile)

        wait_until(fn -> has_element?(view, "[data-testid='registration-closed']") end)
        assert has_element?(view, "[data-testid='session-entry'][disabled]")
        refute has_element?(view, "button[data-testid='calendar-day']")
      end

      @tag :capture_log
      test "says the event has ended once its sessions are over", %{user: user} do
        {profile, meeting_type} = setup_page(user, unquote(theme))
        {:ok, session} = PlannedSessions.add(meeting_type, in_days(3, ~T[18:00:00]))
        past = DateTime.add(DateTime.utc_now(), -86_400, :second)
        age(session, :start_time, past)
        age(session, :end_time, DateTime.add(past, 90, :minute))

        {:ok, view, _html} = open(profile)

        wait_until(fn -> has_element?(view, "[data-testid='sessions-none']") end)
        assert render(view) =~ "This event has ended."
        refute has_element?(view, "button[data-testid='calendar-day']")
      end
    end
  end

  describe "the organiser's page" do
    @tag :capture_log
    test "leaves out a fixed-date type nobody can sign up for", %{user: user} do
      {profile, meeting_type} = setup_page(user, "2")
      insert(:meeting_type, user: user, name: "Solo Call", duration_minutes: 30, is_active: true)

      {:ok, _view, html} = live(build_conn(), "/#{profile.username}?timezone=Etc/UTC")
      refute html =~ "Introduction to X"
      assert html =~ "Solo Call"

      {:ok, _session} = PlannedSessions.add(meeting_type, in_days(3, ~T[18:00:00]))

      {:ok, _view, html} = live(build_conn(), "/#{profile.username}?timezone=Etc/UTC")
      assert html =~ "Introduction to X"
    end
  end
end
