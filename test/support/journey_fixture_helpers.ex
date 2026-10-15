defmodule Tymeslot.JourneyFixtureHelpers do
  @moduledoc """
  Seeding and waits for the journey fixture themes' tests
  (`test/support/journey_fixtures/`, `"96"` Fixture Scroll first).

  The pages are driven through `TymeslotWeb.BookingDriver`; this module only
  seeds the organiser, reads the LiveView's assigns and the rendered markup,
  and waits for what arrives asynchronously (the month's availability, a
  day's times, the confirmation).
  """

  import ExUnit.Assertions, only: [flunk: 1]
  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias Tymeslot.MeetingTypes
  alias Tymeslot.TestHelpers.Eventually
  alias TymeslotWeb.BookingDriver.Page

  @doc """
  A booking-ready organiser on `theme_id`: a profile in UTC, availability
  every day (or the ISO weekdays in `opts[:days]`) from 09:00 to 17:00 up to
  30 days ahead, an active calendar integration, and the meeting types in
  `opts[:types]` (keyword lists for the factory, plus `:custom_fields`, a
  list of question definitions), by default one 30-minute "Quick Chat". `opts[:profile]` adds fields to the profile.
  Returns `%{user:, profile:, meeting_types:}`, the types in order.
  """
  @spec seed_organiser(String.t(), String.t(), keyword()) :: map()
  def seed_organiser(theme_id, username, opts \\ []) do
    user = insert(:user)

    profile =
      insert(
        :profile,
        [user: user, username: username, booking_theme: theme_id, timezone: "UTC"] ++
          Keyword.get(opts, :profile, [])
      )

    schedule =
      insert(:availability_schedule,
        profile: profile,
        is_default: true,
        advance_booking_days: 30,
        min_advance_hours: 0,
        buffer_before_minutes: 0,
        buffer_after_minutes: 0
      )

    for day_of_week <- Keyword.get(opts, :days, 1..7) do
      insert(:weekly_availability,
        schedule: schedule,
        day_of_week: day_of_week,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )
    end

    insert(:calendar_integration, user: user, is_active: true)

    meeting_types =
      opts
      |> Keyword.get(:types, [[name: "Quick Chat", duration_minutes: 30]])
      |> Enum.with_index()
      |> Enum.map(fn {attrs, index} -> insert_meeting_type(user, attrs, index) end)

    %{user: user, profile: profile, meeting_types: meeting_types}
  end

  defp insert_meeting_type(user, attrs, index) do
    {questions, attrs} = Keyword.pop(attrs, :custom_fields, [])

    meeting_type =
      insert(:meeting_type, [user: user, is_active: true, sort_order: index] ++ attrs)

    case questions do
      [] ->
        meeting_type

      questions ->
        {:ok, meeting_type} =
          MeetingTypes.update_meeting_type(meeting_type, %{"custom_fields" => questions})

        meeting_type
    end
  end

  @doc "The LiveView's assigns."
  @spec live_assigns(Phoenix.LiveViewTest.View.t()) :: map()
  defdelegate live_assigns(view), to: Page, as: :assigns

  @doc "Waits until `selector` is on the page."
  @spec await(Phoenix.LiveViewTest.View.t(), String.t()) :: true
  def await(view, selector),
    do: Eventually.eventually(fn -> has_element?(view, selector) end, timeout: 5000)

  @doc "Waits until the month's availability has arrived (or failed)."
  @spec await_availability(Phoenix.LiveViewTest.View.t()) :: true
  def await_availability(view) do
    Eventually.eventually(
      fn -> live_assigns(view)[:availability_status] in [:loaded, :error] end,
      timeout: 5000
    )
  end

  @doc """
  Sends the week view's `load_week` as its `phx-mounted` binding would, once
  the month's availability is in (the landing on the first free day can move
  the week), to the moment component `moment_selector` names, and waits for
  the week.
  """
  @spec load_week(Phoenix.LiveViewTest.View.t(), String.t()) :: :ok
  def load_week(view, moment_selector) do
    await_availability(view)
    view |> with_target(moment_selector) |> render_click("load_week", %{})
    await_week(view)
  end

  @doc "Waits until the week on screen is the week last fetched, and its fetch is done."
  @spec await_week(Phoenix.LiveViewTest.View.t()) :: :ok
  def await_week(view) do
    Eventually.eventually(
      fn ->
        render_async(view)

        match?(%{week_slots: %{}, week_slots_loading: false}, live_assigns(view)) and
          live_assigns(view).week_slots_start == live_assigns(view).current_week_start
      end,
      timeout: 5000
    )

    :ok
  end

  @doc "Every slot time the page offers (`data-fact=\"slot\"`), hidden ones included."
  @spec slot_times(Phoenix.LiveViewTest.View.t()) :: [String.t()]
  def slot_times(view),
    do: view |> Page.attribute("[data-fact='slot']", "data-time") |> Enum.uniq()

  @doc "The first value of `attr` on the elements `selector` matches, or nil."
  @spec first_value(Phoenix.LiveViewTest.View.t(), String.t(), String.t()) :: String.t() | nil
  def first_value(view, selector, attr),
    do: view |> Page.attribute(selector, attr) |> List.first()

  @doc """
  Waits for the chosen day's times (the page lands the visitor on their first
  free day by itself) and returns the first, a `data-fact="time"` value.
  """
  @spec await_first_time(Phoenix.LiveViewTest.View.t()) :: String.t()
  def await_first_time(view) do
    await(view, "[data-fact='time']")
    first_value(view, "[data-fact='time']", "data-value")
  end

  @doc """
  A free day other than `except` among the date buttons on the page, moving
  the month calendar on once when the month shown has none.
  """
  @spec another_free_date(Phoenix.LiveViewTest.View.t(), String.t()) :: String.t()
  def another_free_date(view, except) do
    case free_dates(view) -- [except] do
      [date | _rest] ->
        date

      [] ->
        view |> element("[data-intent='later']:not([disabled])") |> render_click()
        await_availability(view)

        case free_dates(view) -- [except] do
          [date | _rest] -> date
          [] -> flunk("Expected another free day within two months")
        end
    end
  end

  defp free_dates(view),
    do: Page.attribute(view, "[data-fact='date']:not([disabled])", "data-value")
end
