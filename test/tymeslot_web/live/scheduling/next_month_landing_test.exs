defmodule TymeslotWeb.Live.Scheduling.NextMonthLandingTest do
  @moduledoc """
  When nothing is free for the rest of this month, the booking page lands the
  visitor on next month's first free day. That day often sits in the trailing
  row of this month's six-week grid, so it is in the availability map already
  loaded, and the landing used to move the calendar onto next month without
  fetching it: only the few days the old grid reached were clickable, and the
  rest of next month was drawn greyed out.

  The rest of this month is closed with the minimum notice, so the landing
  crosses into next month on any date and at any time of day.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :scheduling
  @moduletag :availability
  @moduletag :integration

  import Ecto.Query, only: [where: 3]
  import Mox
  import Tymeslot.BookingTestHelpers, only: [seed_booking_account: 3]

  alias Tymeslot.Availability.AvailabilityScheduleSchema
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias TymeslotWeb.BookingDriver

  @timezone "Etc/UTC"

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    AvailabilityCache.clear_all()
    TestMocks.setup_all_mocks()

    Tymeslot.CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start, _end -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _user_id -> {:error, :no_integration} end)

    :ok
  end

  # Quill shows the month; Rhythm shows a week, so the day beyond the old
  # grid is reached by paging forward through next month's weeks. Paging
  # fetches each month it reaches, so Rhythm's case holds even without the
  # landing's own fetch: it covers the journey, Quill's covers the fix.
  for {theme_name, theme_id} <- [{"Quill", "1"}, {"Rhythm", "2"}] do
    @tag :capture_log
    @tag theme_id: theme_id
    test "#{theme_name}: landing on next month's first free day makes the whole of next month bookable",
         %{conn: conn, theme_id: theme_id} do
      %{profile: profile} = seed_booking_account(theme_id, "next-month-#{theme_id}", @timezone)

      today = Date.utc_today()
      next_month = today |> Date.end_of_month() |> Date.add(1)

      # Notice running into next month's first day closes the rest of this one;
      # sixty days keeps the 20th of next month inside the booking window.
      AvailabilityScheduleSchema
      |> where([s], s.profile_id == ^profile.id)
      |> Repo.update_all(
        set: [
          min_advance_hours: Date.diff(next_month, today) * 24,
          advance_booking_days: 60
        ]
      )

      {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=#{@timezone}")
      BookingDriver.choose_meeting_type(view, "quick-chat")
      BookingDriver.continue(view)

      # The landing picks a day of next month; paging before it settles would
      # be undone by it.
      landed =
        "[data-fact='date']:not([data-alternate])[aria-pressed='true'][data-value^='#{Calendar.strftime(next_month, "%Y-%m")}']"

      wait_until(fn -> has_element?(view, landed) end)

      # A six-week grid reaches at most 14 days into the next month, so the
      # 20th is a day only next month's own availability can open.
      beyond_old_grid = next_month |> Date.add(19) |> Date.to_iso8601()
      selector = "[data-fact='date']:not([data-alternate])[data-value='#{beyond_old_grid}']"

      BookingDriver.show_date(view, beyond_old_grid)
      wait_until(fn -> has_element?(view, selector <> ":not([disabled])") end)

      assert has_element?(view, selector <> ":not([disabled])")
    end
  end
end
