defmodule Tymeslot.BookingTestHelpers do
  @moduledoc """
  Test helpers for booking flow navigation and common booking test
  operations. The walks go through `TymeslotWeb.BookingDriver`, which finds a
  page's controls by the markup contract alone, so they hold on every theme.
  """

  import ExUnit.Assertions
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias TymeslotWeb.BookingDriver
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers

  @endpoint TymeslotWeb.Endpoint

  # Quill's month arrows and its month label, for the Quill tests that ask
  # which month its grid shows; a walk moves any picker through the driver.
  @next_month "button[phx-click='next_month']"
  @prev_month "button[phx-click='prev_month']"
  @month_label ".calendar-month-label"

  @doc """
  Inserts a booking-ready organiser: profile, an active 30-minute meeting type,
  full-week availability, and an active calendar integration (so the page is
  publicly ready). Returns `%{user: user, profile: profile}`.
  """
  @spec seed_booking_account(String.t(), String.t(), String.t()) :: %{
          user: map(),
          profile: map()
        }
  def seed_booking_account(theme_id, username, timezone) do
    user = insert(:user)

    profile =
      insert(:profile,
        user: user,
        username: username,
        booking_theme: theme_id,
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

    insert(:meeting_type, user: user, duration_minutes: 30, name: "Quick Chat", is_active: true)

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

  @doc """
  Navigates through the complete booking flow from profile page to booking form.

  This helper performs the following steps:
  1. Visits the profile page
  2. Selects the first meeting type
  3. Navigates to date/time selection
  4. Waits for availability to load
  5. Selects tomorrow's first free time
  6. Navigates to the booking form (or to the questions, when the meeting
     type asks some)

  Returns the LiveView at that step.

  ## Examples

      view = navigate_to_booking_form(conn, profile, event_type)
      # Now you can submit the booking form
  """
  @spec navigate_to_booking_form(Plug.Conn.t(), struct(), struct()) ::
          Phoenix.LiveViewTest.View.t()
  def navigate_to_booking_form(conn, profile, event_type),
    do: navigate_to_booking_form(conn, profile, event_type, [])

  @doc """
  As `navigate_to_booking_form/3`, with extra query params merged into the
  scheduling page URL.

  The reschedule journey needs `reschedule_meeting_uid` present from the first
  render: `LiveHelpers.Mount` reads it out of the params to set `is_rescheduling`,
  and without it the identical walk silently books a *new* meeting instead of
  moving the existing one.
  """
  @spec navigate_to_booking_form(Plug.Conn.t(), struct(), struct(), keyword() | list()) ::
          Phoenix.LiveViewTest.View.t()
  def navigate_to_booking_form(conn, profile, _event_type, query_params) do
    timezone = profile.timezone
    query = URI.encode_query([{"timezone", timezone} | Enum.to_list(query_params)])
    {:ok, view, _html} = live(conn, "/#{profile.username}?#{query}")

    walk_to_booking_form(view, timezone)
  end

  @doc """
  Walks an already-mounted scheduling view from the overview step through to
  the booking form, which is what `navigate_to_booking_form/4` does once it has
  mounted one of its own.

  Public because the flow can restart without a mount to hang off: "Schedule
  Another Meeting" returns the same LiveView to the overview step in place, and
  the walk that follows has to start from the view already on screen.

  `duration_slug` names the meeting type to book, defaulting to whichever the
  overview lists first. The time is tomorrow's first free one, never today's:
  today's times may already be past the cutoff.
  """
  @spec walk_to_booking_form(Phoenix.LiveViewTest.View.t(), String.t(), String.t() | nil) ::
          Phoenix.LiveViewTest.View.t()
  def walk_to_booking_form(view, timezone, duration_slug \\ nil) do
    BookingDriver.choose_meeting_type(view, duration_slug || first_meeting_type(view))
    BookingDriver.continue(view)

    tomorrow =
      timezone |> DateTime.now!() |> DateTime.to_date() |> Date.add(1) |> Date.to_iso8601()

    _picked = BookingDriver.pick_first_slot(view, on: tomorrow)
    BookingDriver.continue(view)

    view
  end

  defp first_meeting_type(view) do
    case BookingDriver.meeting_types(view) do
      [slug | _rest] -> slug
      [] -> flunk("Expected at least one meeting type card on the overview step")
    end
  end

  @doc """
  Brings `date`'s month onto Quill's month grid, stepping one month towards
  `direction` (`:next` or `:prev`) only if the grid is not showing it already.

  The only way to move the month in a booking test. The schedule step opens on
  the first bookable day, so whether the grid still shows today's month depends
  on the hour and the day of the month the suite happens to run on; see
  `showing_month?/2` for what goes wrong when the step is computed instead.
  Two directions because two questions get asked: a walk towards a later date
  steps forward, and a test about today's own cell steps back to it.

  Asserts the month is on screen afterwards, so an overshoot or a step the
  wrong way fails here, by name, rather than as a five-second wait timeout
  further down.
  """
  @spec show_month(Phoenix.LiveViewTest.View.t(), Date.t(), :next | :prev) :: :ok
  def show_month(view, %Date{} = date, direction \\ :next) when direction in [:next, :prev] do
    unless showing_month?(view, date) do
      view |> element(month_arrow(direction)) |> render_click()
    end

    assert showing_month?(view, date),
           "expected the calendar to show #{Calendar.strftime(date, "%B %Y")} " <>
             "after at most one step #{direction}"

    :ok
  end

  defp month_arrow(:next), do: @next_month
  defp month_arrow(:prev), do: @prev_month

  @doc """
  Whether the month grid is currently displaying `date`'s month.

  Public because every booking walk needs this question answered, and answering
  it by arithmetic is wrong. The schedule step opens on the first bookable day,
  so on the last day of a month, once today's cutoff has passed, the grid is
  already showing the next month before any navigation happens. A guard written
  as `if target.month != today.month` then advances a calendar that has moved
  itself: either the arrow is disabled at the far edge of the booking window and
  the click raises, or it succeeds and overshoots, leaving the target behind.

  Quill's grid pads with the neighbouring month's days and disables them, so a
  rendered day cell proves nothing about which month is on screen. The month
  label does, which is what this reads.
  """
  @spec showing_month?(Phoenix.LiveViewTest.View.t(), Date.t()) :: boolean()
  def showing_month?(view, %Date{} = date) do
    has_element?(
      view,
      @month_label,
      LocalizationHelpers.get_month_year_display(date.year, date.month)
    )
  end
end
