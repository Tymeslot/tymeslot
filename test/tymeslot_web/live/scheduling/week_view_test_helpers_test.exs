defmodule Tymeslot.WeekViewTestHelpersTest do
  @moduledoc """
  The shared flow suites pick a time through `ThemeBookingFlowHelpers` and
  `BookingTestHelpers`, whatever picker the theme's schedule step shows. These
  pin the week grid path on the fixture theme (`test/support/fixture_theme/`:
  its schedule step is the shared `WeekGrid`, its booking step the shared
  form), so the path is proved before a shipped theme with a week view takes
  it. Quill's and Rhythm's path is pinned by every shared flow suite.
  """
  use TymeslotWeb.LiveCase, async: false

  @moduletag :scheduling
  @moduletag :integration

  import Mox
  import Tymeslot.BookingTestHelpers, only: [walk_to_booking_form: 2]
  import Tymeslot.ThemeBookingFlowHelpers, only: [seed_booking_account: 3, select_first_slot: 1]

  alias Ecto.Changeset
  alias Tymeslot.Availability.AvailabilityScheduleSchema
  alias Tymeslot.CalendarMock
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  @fixture_theme_id "99"
  @timezone "Etc/UTC"

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    AvailabilityCache.clear_all()
    TestMocks.setup_all_mocks()

    CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start, _end -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _user_id -> {:error, :no_integration} end)

    :ok
  end

  @tag :capture_log
  test "select_first_slot/1 picks the grid's first free time, the day and the time together",
       %{conn: conn} do
    %{profile: profile} = seed_booking_account(@fixture_theme_id, "week-helper-first", @timezone)
    {:ok, view, _html} = live(conn, "/#{profile.username}/quick-chat?timezone=#{@timezone}")

    {date, time} = select_first_slot(view)

    assert %{selected_date: ^date, selected_time: ^time} = live_assigns(view)

    assert has_element?(
             view,
             "[data-testid='week-slot'][data-date='#{date}'][data-time='#{time}'][aria-pressed='true']"
           )

    refute has_element?(view, "button[data-testid='next-step'][disabled]")
  end

  @tag :capture_log
  test "select_first_slot/1 finds the first free time more than a week out", %{conn: conn} do
    %{profile: profile} = seed_booking_account(@fixture_theme_id, "week-helper-later", @timezone)

    AvailabilityScheduleSchema
    |> Repo.get_by!(profile_id: profile.id)
    |> Changeset.change(min_advance_hours: 8 * 24)
    |> Repo.update!()

    {:ok, view, _html} = live(conn, "/#{profile.username}/quick-chat?timezone=#{@timezone}")

    {date, _time} = select_first_slot(view)

    assert Date.diff(Date.from_iso8601!(date), Date.utc_today()) >= 8
  end

  @tag :capture_log
  test "walk_to_booking_form/2 reaches the form with tomorrow's first time from the grid",
       %{conn: conn} do
    %{profile: profile} = seed_booking_account(@fixture_theme_id, "week-helper-walk", @timezone)
    {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=#{@timezone}")

    walk_to_booking_form(view, @timezone)

    assert has_element?(view, "form[data-testid='booking-form']")

    assert live_assigns(view).selected_date ==
             Date.utc_today() |> Date.add(1) |> Date.to_iso8601()
  end

  defp live_assigns(view), do: :sys.get_state(view.pid).socket.assigns
end
