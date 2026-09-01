defmodule Tymeslot.SlotPickerTestHelpers do
  @moduledoc """
  Fixture and page-reading helpers shared by the two themes' slot-picker tests.

  Both themes present the same feature over the same organiser setup, so the
  fixture and the generic attribute reads live here. What stays in each theme's
  own test file is the part that is genuinely per-theme: how its calendar is
  navigated (Quill pages by month, Rhythm by week), which selector its slot
  buttons answer to, and every assertion. That split is deliberate — sharing the
  assertions too would leave a failure unable to say which theme broke.
  """

  import Phoenix.LiveViewTest, only: [render: 1]
  import Tymeslot.Factory

  alias Tymeslot.Availability.TimeSlots
  alias Tymeslot.Utils.DateTimeUtils.Display

  @doc """
  Inserts an organiser bookable 09:00–17:00 every day, on the given theme.

  `booking_theme` is the theme id: `"1"` for Quill, `"2"` for Rhythm.
  """
  @spec booking_page(String.t(), String.t()) :: %{user: struct(), profile: struct()}
  def booking_page(username, booking_theme) do
    user = insert(:user)

    profile =
      insert(:profile,
        user: user,
        username: username,
        booking_theme: booking_theme,
        timezone: "America/New_York"
      )

    schedule =
      insert(:availability_schedule,
        profile: profile,
        is_default: true,
        advance_booking_days: 30,
        min_advance_hours: 0,
        buffer_minutes: 0
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

    %{user: user, profile: profile}
  end

  @doc "Parses the view's current render for attribute reads."
  @spec document(term()) :: Floki.html_tree()
  def document(view), do: view |> render() |> Floki.parse_document!()

  @doc """
  The hours the page is currently offering, ascending.

  Read off the rendered attributes rather than recomputed from the grouping
  code, so an assertion built on this cannot agree with a bug in that code.
  """
  @spec rendered_hours(term()) :: [integer()]
  def rendered_hours(view) do
    view
    |> document()
    |> Floki.attribute("[data-testid='slot-hour']", "phx-value-hour")
    |> Enum.map(&String.to_integer/1)
    |> Enum.sort()
  end

  @doc """
  The same minute as a slot already on the page, moved into `hour`.

  Lets a test name a time inside a closed hour without hardcoding a clock
  value that would drift if the fixture's window moved.
  """
  @spec minute_of([String.t()], integer()) :: String.t()
  def minute_of(times, hour) do
    times
    |> List.first()
    |> TimeSlots.parse_time_slot()
    |> Map.put(:hour, hour)
    |> Display.format_time_for_display()
  end
end
