defmodule TymeslotWeb.Live.Scheduling.AvailabilityAsyncFetchTest do
  @moduledoc """
  Covers the availability fetch as production runs it: in a task.

  The rest of the suite runs with `:async_availability_fetch` set
  `false`, which computes the same result inline and delivers it through
  the same `{ref, result}` message. That keeps every test deterministic
  and every *downstream* step — the ref match, the loaded and error
  transitions, the landing on the first bookable day — on the production
  code path. What it cannot cover is the task itself, so this module
  turns the flag back on and drives it.

  Three things are asserted, because each fails differently:

    * the fetch genuinely runs off the LiveView process, and the booker
      still ends up on a bookable day with its times listed;
    * a calendar that errors leaves the page on the error state rather
      than a permanent spinner, with the landing attempt spent;
    * a result for a superseded fetch is discarded rather than painted
      over the window the booker has since moved to.

  The first assertion is what makes this module more than a duplicate of
  `NextAvailableTest`: it fails if the flag stops selecting the task
  path, which is exactly the regression the deterministic harness would
  otherwise hide.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :scheduling
  @moduletag :live

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()
    TestMocks.setup_all_mocks()

    previous = Application.get_env(:tymeslot, :async_availability_fetch)
    Application.put_env(:tymeslot, :async_availability_fetch, true)
    on_exit(fn -> Application.put_env(:tymeslot, :async_availability_fetch, previous) end)

    user = insert(:user)

    profile =
      insert(:profile,
        user: user,
        username: "asyncfetch",
        booking_theme: "1",
        timezone: "America/New_York"
      )

    schedule =
      insert(:availability_schedule,
        profile: profile,
        is_default: true,
        advance_booking_days: 90,
        min_advance_hours: 0,
        buffer_minutes: 0
      )

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

    insert(:calendar_integration, user: user, is_active: true)

    %{profile: profile, user: user}
  end

  @tag :capture_log
  test "the fetch runs off the LiveView process and still lands on a bookable day",
       %{conn: conn, profile: profile} do
    test_pid = self()

    # The calendar read is the only thing inside the fetch closure that can
    # report where it ran, so it is what pins the branch: with the flag off
    # this arrives from the LiveView process itself.
    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      send(test_pid, {:fetched_in, self()})
      {:ok, []}
    end)

    {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=#{profile.timezone}")
    settle_availability(view)

    view |> element("button[data-testid='duration-option']") |> render_click()
    settle_availability(view)

    view |> element("button[data-testid='next-step']") |> render_click()

    wait_until(fn -> has_element?(view, "button.time-slot-button") end)

    assert_received {:fetched_in, fetch_pid}

    refute fetch_pid == view.pid,
           "the availability fetch ran inside the LiveView, not in a task"

    refute fetch_pid == test_pid

    state = :sys.get_state(view.pid).socket.assigns
    assert state.availability_status == :loaded
    assert {:ok, %Date{}} = Date.from_iso8601(state.selected_date)
    assert render(view) =~ state.selected_date
  end

  @tag :capture_log
  test "a calendar that errors leaves the page on the error state, not a spinner",
       %{conn: conn, profile: profile} do
    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      {:error, :all_calendars_unavailable}
    end)

    {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=#{profile.timezone}")
    settle_availability(view)

    view |> element("button[data-testid='duration-option']") |> render_click()
    settle_availability(view)

    view |> element("button[data-testid='next-step']") |> render_click()

    wait_until(fn ->
      :sys.get_state(view.pid).socket.assigns[:availability_status] == :error
    end)

    state = :sys.get_state(view.pid).socket.assigns

    # The map is cleared rather than left on :loading — the calendar grid
    # renders :loading as a spinner on every square, which for a failed
    # fetch never resolves.
    assert state.month_availability_map == nil
    assert state.availability_task == nil
    assert state.availability_task_ref == nil

    # No day is picked out of a map that does not exist, and the one
    # landing attempt is spent, so the next successful fetch does not drag
    # the calendar back onto a day chosen for a window the booker has left.
    assert state.selected_date == nil
    assert state.auto_select_settled == true

    assert render(view) =~ "Calendar is loading slowly"
  end

  @tag :capture_log
  test "a result for a superseded fetch is discarded", %{conn: conn, profile: profile} do
    {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=#{profile.timezone}")
    settle_availability(view)

    view |> element("button[data-testid='duration-option']") |> render_click()
    settle_availability(view)

    view |> element("button[data-testid='next-step']") |> render_click()

    wait_until(fn ->
      :sys.get_state(view.pid).socket.assigns[:availability_status] == :loaded
    end)

    loaded = :sys.get_state(view.pid).socket.assigns.month_availability_map
    assert loaded != %{}

    # A ref that was never this socket's — the shape a fetch launched for a
    # month the booker has since navigated away from arrives in.
    send(view.pid, {make_ref(), {:ok, %{"2020-01-01" => true}}})

    # Round-trip through the LiveView so the message above is definitely
    # processed before the assertion reads the assigns back.
    _html = render(view)

    state = :sys.get_state(view.pid).socket.assigns
    assert state.month_availability_map == loaded
    assert state.availability_status == :loaded
  end

  # Every step of the flow that re-enters the schedule view cancels the
  # fetch still in flight with `Task.shutdown(:brutal_kill)`. Killing a task
  # part-way through its calendar query takes the checked-out sandbox
  # connection with it and drops the pool back to `:manual` for the rest of
  # the run — which is the concrete reason the suite at large runs with
  # `:async_availability_fetch` off rather than merely a preference for
  # determinism. Letting each fetch finish before provoking the next keeps
  # the cancellation a no-op.
  defp settle_availability(view) do
    wait_until(fn ->
      assigns = :sys.get_state(view.pid).socket.assigns

      assigns[:availability_status] in [:loaded, :error] and
        assigns[:availability_task] == nil
    end)
  end
end
