defmodule Tymeslot.ThemeBookingFlowHelpers do
  @moduledoc """
  Shared helpers for driving the public booking flow in LiveView tests.

  Keeps the multi-step "select duration → date → slot → submit" choreography in
  one place so feature tests (a real end-to-end booking, an owner-preview
  simulated booking, …) read as intent rather than repeating the same clicks.
  """

  import ExUnit.Assertions, only: [flunk: 1]
  import Phoenix.LiveViewTest
  import Tymeslot.Factory
  import Tymeslot.TestHelpers.Eventually

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
        timezone: timezone,
        advance_booking_days: 30,
        min_advance_hours: 0,
        buffer_minutes: 0
      )

    insert(:meeting_type, user: user, duration_minutes: 30, name: "Quick Chat", is_active: true)

    Enum.each(1..7, fn day_of_week ->
      insert(:weekly_availability,
        profile: profile,
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
  Drives an already-mounted booking view from overview through to the
  confirmation step (select duration → date → slot → fill + submit the form),
  returning the rendered confirmation HTML.
  """
  @spec complete_booking_flow(term(), String.t(), String.t(), map()) :: binary()
  def complete_booking_flow(view, theme_name, theme_id, attendee) do
    fill_and_submit_booking_flow(view, theme_name, theme_id, attendee)

    eventually(fn -> has_element?(view, "[data-testid='confirmation-heading']") end,
      timeout: 10_000
    )

    render(view)
  end

  @doc """
  Drives an already-mounted booking view from overview through form submission
  (select duration → date → slot → fill + submit) WITHOUT waiting for a
  confirmation view.

  Use this when the submission is expected NOT to confirm — e.g. a preview page
  whose owner token is missing/expired, where the booking must be blocked rather
  than persisted. The caller asserts the resulting blocked/error state itself.
  """
  @spec fill_and_submit_booking_flow(term(), String.t(), String.t(), map()) :: :ok
  def fill_and_submit_booking_flow(view, theme_name, theme_id, attendee) do
    view
    |> element("button[data-testid='duration-option'][data-duration='quick-chat']")
    |> render_click()

    view |> element("button[data-testid='next-step']") |> render_click()

    target_date = next_business_day(Date.utc_today())
    date_str = Date.to_string(target_date)

    navigate_calendar_to_date(view, theme_name, target_date)

    eventually(
      fn ->
        has_element?(
          view,
          "button[data-testid='calendar-day'][phx-value-date='#{date_str}']:not([disabled])"
        )
      end,
      timeout: 5000
    )

    view
    |> element("button[data-testid='calendar-day'][phx-value-date='#{date_str}']")
    |> render_click()

    eventually(fn -> has_element?(view, "button[data-testid='time-slot']") end, timeout: 5000)

    slot = view |> render() |> Floki.parse_document!() |> first_slot_time()

    view
    |> element("button[data-testid='time-slot'][phx-value-time='#{slot}']")
    |> render_click()

    eventually(
      fn -> not has_element?(view, "button[data-testid='next-step'][disabled]") end,
      timeout: 5000
    )

    view |> element("button[data-testid='next-step']") |> render_click()

    eventually(fn -> has_element?(view, "form[data-testid='booking-form']") end, timeout: 5000)
    submit_booking_form(view, theme_id, attendee)

    :ok
  end

  @doc "Fills and submits the booking form with the given attendee details."
  @spec submit_booking_form(term(), String.t(), map()) :: binary()
  def submit_booking_form(view, _theme_id, %{name: name, email: email, message: message}) do
    view
    |> form("form[data-testid='booking-form']", %{
      "booking" => %{"name" => name, "email" => email, "message" => message}
    })
    |> render_submit()
  end

  @doc "Returns the first available time-slot value rendered on the schedule step."
  @spec first_slot_time(term()) :: String.t()
  def first_slot_time(doc) do
    val = List.first(Floki.attribute(doc, "button[data-testid='time-slot']", "phx-value-time"))

    case val do
      nil ->
        data_time =
          List.first(Floki.attribute(doc, "button[data-testid='time-slot']", "data-time"))

        case data_time do
          nil -> flunk("Expected at least one available time slot after selecting a date")
          slot -> slot
        end

      slot ->
        slot
    end
  end

  @doc "Advances the calendar/week strip so `target_date` is reachable for the theme."
  @spec navigate_calendar_to_date(term(), String.t(), Date.t()) :: :ok | binary()
  def navigate_calendar_to_date(view, theme_name, target_date) do
    today = Date.utc_today()

    case theme_name do
      "quill" ->
        if target_date.year > today.year ||
             (target_date.year == today.year && target_date.month > today.month) do
          view |> element("button[phx-click='next_month']") |> render_click()
        end

      "rhythm" ->
        week_start = Date.beginning_of_week(today, :monday)
        week_end = Date.add(week_start, 6)

        if Date.compare(target_date, week_end) == :gt do
          view |> element("button[phx-click='next_week']") |> render_click()
        end

      _date ->
        :ok
    end
  end

  @doc "Returns the next weekday strictly after `start_date`."
  @spec next_business_day(Date.t()) :: Date.t()
  def next_business_day(%Date{} = start_date) do
    Enum.find_value(1..14, fn offset ->
      date = Date.add(start_date, offset)
      dow = Date.day_of_week(date)
      if dow in 1..5, do: date, else: nil
    end) || Date.add(start_date, 1)
  end
end
