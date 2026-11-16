defmodule TymeslotWeb.BookableLayerHelpers do
  @moduledoc """
  Bookable times for the calendar surface's tests, on top of
  `TymeslotWeb.CalendarSurfaceHelpers.owner/2` (clock frozen at 09:00 London
  on Wednesday 14 October 2026).

  `open_days/2` opens the organiser 09:00 to 17:00 London time on the given
  ISO weekdays (Monday, Tuesday, Thursday and Friday by default, so the
  frozen today is closed and the first bookable time is Thursday 15 October
  at 09:00), with no buffers and no notice, so a 30-minute meeting type is
  bookable for the whole of those hours.
  """

  import ExUnit.Assertions
  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias Tymeslot.Profiles

  @doc "Opens the organiser's default schedule 09:00 to 17:00 on `days`."
  @spec open_days(map(), [1..7]) :: %{profile: map(), schedule: map()}
  def open_days(user, days \\ [1, 2, 4, 5]) do
    profile = Profiles.get_profile(user.id)

    schedule =
      insert(:availability_schedule,
        profile: profile,
        is_default: true,
        buffer_before_minutes: 0,
        buffer_after_minutes: 0,
        min_advance_hours: 0
      )

    for day <- days do
      insert(:weekly_availability,
        schedule: schedule,
        day_of_week: day,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )
    end

    %{profile: profile, schedule: schedule}
  end

  @doc "An active 30-minute \"Intro call\" for `user`, first in their order."
  @spec meeting_type(map(), keyword()) :: map()
  def meeting_type(user, attrs \\ []) do
    insert(
      :meeting_type,
      Keyword.merge([user: user, name: "Intro call", duration_minutes: 30, sort_order: 0], attrs)
    )
  end

  @doc """
  The next `calendar:bookable` push for which `predicate` holds, waiting for
  the surface's async work first. Pushes that do not match are skipped, so
  a reload a broadcast scheduled earlier cannot be mistaken for the one the
  test waits for. Fails after `timeout` milliseconds.
  """
  @spec await_bookable(Phoenix.LiveViewTest.View.t(), (map() -> boolean()), pos_integer()) ::
          map()
  def await_bookable(lv, predicate, timeout \\ 2_000) do
    render_async(lv, timeout)
    await(lv, predicate, System.monotonic_time(:millisecond) + timeout)
  end

  defp await(lv, predicate, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)
    assert_push_event(lv, "calendar:bookable", payload, remaining)

    if predicate.(payload), do: payload, else: await(lv, predicate, deadline)
  end

  @doc "Whether the pushed layer has a window starting on `iso` (\"2026-10-15\")."
  @spec on_day?(map(), String.t()) :: boolean()
  def on_day?(%{windows: windows}, iso),
    do: Enum.any?(windows, &String.starts_with?(&1.start, iso))
end
