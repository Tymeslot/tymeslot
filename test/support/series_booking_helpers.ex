defmodule TymeslotWeb.SeriesBookingHelpers do
  @moduledoc """
  What the per-theme series suites share (`*_series_test.exs` under
  `test/tymeslot_web/live/scheduling/`): the setup that mocks the calendar
  and turns the booking reCAPTCHA off, the series meeting types, an
  organiser on a given theme, and the walk to the series moment and on to
  the details through `TymeslotWeb.BookingDriver`.

  A theme is either paged, with a way on to and from its series moment
  (`reveal: false`), or shows the series below the time on the same page and
  the details below the series once every session is available
  (`reveal: true`), with no way on to press.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]
  import Mox
  import Phoenix.ConnTest, only: [get: 2]
  import Phoenix.LiveViewTest
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory
  import Tymeslot.JourneyFixtureHelpers, only: [seed_organiser: 3]

  import Ecto.Query, only: [from: 2]

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.TestMocks
  alias TymeslotWeb.BookingDriver

  @endpoint TymeslotWeb.Endpoint

  @doc "A weekly series of four sessions at the time picked."
  @spec weekly() :: keyword()
  def weekly,
    do: [
      name: "Weekly Coaching",
      duration_minutes: 30,
      series_mode: :recurring,
      series_frequency: :weekly,
      series_interval: 1,
      series_min_occurrences: 4,
      series_max_occurrences: 4
    ]

  @doc "A flexible series of exactly three sessions, each picked."
  @spec flexible() :: keyword()
  def flexible,
    do: [
      name: "Flexible Pack",
      duration_minutes: 30,
      series_mode: :flexible,
      series_min_occurrences: 3,
      series_max_occurrences: 3
    ]

  @doc """
  The setup every series suite runs: rate limits and the availability cache
  cleared, payments on, the booking reCAPTCHA off, an empty calendar.
  Returns `%{day: tomorrow}`.
  """
  @spec setup_series(map()) :: map()
  def setup_series(tags) do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    AvailabilityCache.clear_all()

    setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      meeting_payments_enabled: true,
      payment_application_fee_bp: 50
    )

    recaptcha = Application.get_env(:tymeslot, :recaptcha, [])
    Application.put_env(:tymeslot, :recaptcha, Keyword.put(recaptcha, :booking_enabled, false))
    on_exit(fn -> Application.put_env(:tymeslot, :recaptcha, recaptcha) end)

    TestMocks.setup_all_mocks()

    Tymeslot.CalendarMock
    |> stub(:get_events_for_range_fresh, fn _user_id, _start, _end -> {:ok, []} end)
    |> stub(:get_booking_integration_info, fn _context -> {:error, :no_integration} end)

    %{day: Date.add(Date.utc_today(), 1)}
  end

  @doc """
  Holds every read of the host's calendar from now on, so a series check
  started next stays in flight until `release_calendar/1`. Returns the
  gate. The reads wait in their own processes and tell the test they are
  waiting (`{:calendar_held, pid}`).
  """
  @spec hold_calendar() :: pid()
  def hold_calendar do
    test = self()
    {:ok, gate} = Agent.start_link(fn -> {:held, []} end)

    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      if wait_at(gate) == :held do
        send(test, {:calendar_held, self()})

        receive do
          :release -> :ok
        end
      end

      {:ok, []}
    end)

    gate
  end

  # Registers the reader at a held gate in the same step that reads it, so
  # a release never misses a reader that saw the gate held.
  defp wait_at(gate) do
    reader = self()

    Agent.get_and_update(gate, fn
      {:held, readers} -> {:held, {:held, [reader | readers]}}
      :open -> {:open, :open}
    end)
  end

  @doc "Lets every held calendar read, and every later one, through."
  @spec release_calendar(pid()) :: :ok
  def release_calendar(gate) do
    gate
    |> Agent.get_and_update(fn
      {:held, readers} -> {readers, :open}
      :open -> {[], :open}
    end)
    |> Enum.each(&send(&1, :release))
  end

  @doc "An organiser on `theme_id` offering the one meeting type `type_attrs`."
  @spec organiser(String.t(), String.t(), keyword()) :: map()
  def organiser(theme_id, username, type_attrs),
    do: seed_organiser(theme_id, username, types: [type_attrs])

  @doc """
  Opens the organiser's page, chooses the type, picks the first time on
  `day` and reaches the series moment, once its check has answered.
  """
  @spec to_series(Plug.Conn.t(), map(), Date.t(), keyword()) :: Phoenix.LiveViewTest.View.t()
  def to_series(conn, profile, day, opts) do
    {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=Etc/UTC")

    BookingDriver.choose_meeting_type(view, hd(BookingDriver.meeting_types(view)))
    {_iso, _time} = BookingDriver.pick_first_slot(view, on: Date.to_iso8601(day))
    unless Keyword.fetch!(opts, :reveal), do: BookingDriver.continue(view)
    render_async(view)

    assert has_element?(view, "[data-testid='series-step']")
    view
  end

  @doc """
  Moves on from a series every session of which is available to the
  details: the way on on a paged theme; on one that reveals, the details
  are already below.
  """
  @spec to_details(Phoenix.LiveViewTest.View.t(), keyword()) :: :ok
  def to_details(view, opts) do
    unless Keyword.fetch!(opts, :reveal), do: BookingDriver.continue(view)
    render_async(view)
    assert has_element?(view, "form[data-fact='attendee']")
    :ok
  end

  @doc "The session rows on screen, those with `status` when given."
  @spec occurrences(Phoenix.LiveViewTest.View.t(), String.t() | nil) :: list()
  def occurrences(view, status \\ nil) do
    selector =
      if status,
        do: "[data-testid='series-occurrence'][data-status='#{status}']",
        else: "[data-testid='series-occurrence']"

    view |> render() |> Floki.parse_document!() |> Floki.find(selector)
  end

  @doc "The booked sessions on a confirmation `html`."
  @spec booked_sessions(String.t()) :: list()
  def booked_sessions(html),
    do: html |> Floki.parse_document!() |> Floki.find("[data-testid='series-booked-session']")

  @doc "The organiser's meetings, by start."
  @spec meetings(map()) :: [MeetingSchema.t()]
  def meetings(user) do
    Repo.all(
      from(m in MeetingSchema,
        where: m.organizer_user_id == ^user.id,
        order_by: m.start_time
      )
    )
  end

  @doc "A confirmed meeting of the organiser's at `start`, clashing with a session."
  @spec clash(map(), DateTime.t()) :: MeetingSchema.t()
  def clash(user, start) do
    insert(:meeting,
      organizer_user_id: user.id,
      start_time: start,
      end_time: DateTime.add(start, 30, :minute),
      status: :confirmed
    )
  end

  @doc "09:00 UTC on `day`, `weeks_later` weeks on: the first time a day offers."
  @spec at_nine(Date.t(), non_neg_integer()) :: DateTime.t()
  def at_nine(day, weeks_later),
    do: day |> Date.add(weeks_later * 7) |> DateTime.new!(~T[09:00:00], "Etc/UTC")

  @doc "Opens the flexible picker and adds the last free time of its `index`th day."
  @spec add_last_time_of_day(Phoenix.LiveViewTest.View.t(), integer()) :: :ok
  def add_last_time_of_day(view, index) do
    view |> element("[data-testid='series-add']") |> render_click()
    render_async(view)

    days = attribute_values(view, "[data-testid='series-picker-day']", "data-date")

    view
    |> element("[data-testid='series-picker-day'][data-date='#{Enum.at(days, index)}']")
    |> render_click()

    starts = attribute_values(view, "[data-testid='series-picker-time']", "data-value")

    view
    |> element("[data-testid='series-picker-time'][data-value='#{List.last(starts)}']")
    |> render_click()

    render_async(view)
    :ok
  end

  defp attribute_values(view, selector, attribute) do
    view
    |> render()
    |> Floki.parse_document!()
    |> Floki.find(selector)
    |> Enum.flat_map(&Floki.attribute(&1, attribute))
  end
end
