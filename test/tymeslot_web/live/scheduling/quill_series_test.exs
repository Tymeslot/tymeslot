defmodule TymeslotWeb.Live.Scheduling.QuillSeriesTest do
  @moduledoc """
  Booking a series on the Quill theme, end to end: the booker picks a time,
  which is the first session, chooses the series on the series moment, fills
  in the form and lands on a confirmation listing every session.

  Covers a recurring series (its count, a clash named on its date, a session
  lost between the check and the submit), a flexible series picked session
  by session, a single session where the series is optional, a paid series
  sent to Stripe Checkout, a series held for the host's approval, and a host
  whose plan does not include series, whose bookers get the single-session
  flow. Mocked are the boundaries only: the calendar provider and Stripe.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :scheduling
  @moduletag :live

  import Ecto.Query, only: [from: 2]
  import Mox
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory
  import Tymeslot.JourneyFixtureHelpers, only: [seed_organiser: 3]

  alias Tymeslot.BookingSeries.SeriesSchema
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.StripeStub
  alias Tymeslot.StripeStubResponses
  alias Tymeslot.TestMocks
  alias TymeslotWeb.BookingDriver

  @quill "1"
  @checkout_url "https://checkout.stripe.com/c/pay/cs_SERIES"

  @weekly [
    name: "Weekly Coaching",
    duration_minutes: 30,
    series_mode: :recurring,
    series_frequency: :weekly,
    series_interval: 1,
    series_min_occurrences: 4,
    series_max_occurrences: 4
  ]

  @flexible [
    name: "Flexible Pack",
    duration_minutes: 30,
    series_mode: :flexible,
    series_min_occurrences: 2,
    series_max_occurrences: 3
  ]

  defmodule DenyChecker do
    @moduledoc false
    @behaviour Tymeslot.Features.CheckerBehaviour
    @impl Tymeslot.Features.CheckerBehaviour
    def check_access(_user_id, :recurring_bookings_allowed), do: {:error, :insufficient_plan}
    def check_access(_user_id, _feature), do: :ok
  end

  setup :verify_on_exit!

  setup tags do
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

  defp organiser(username, type_attrs, opts \\ []) do
    seed_organiser(@quill, username, Keyword.merge([types: [type_attrs]], opts))
  end

  # Opens the page, chooses the type, picks the first time on `day` and moves
  # on to the series moment, once its check has answered.
  defp to_series(conn, profile, day) do
    {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=Etc/UTC")

    BookingDriver.choose_meeting_type(view, hd(BookingDriver.meeting_types(view)))
    {_iso, _time} = BookingDriver.pick_first_slot(view, on: Date.to_iso8601(day))
    BookingDriver.continue(view)
    render_async(view)

    view
  end

  defp at_nine(day, weeks_later),
    do: day |> Date.add(weeks_later * 7) |> DateTime.new!(~T[09:00:00], "Etc/UTC")

  defp occurrences(view, status \\ nil) do
    selector =
      if status,
        do: "[data-testid='series-occurrence'][data-status='#{status}']",
        else: "[data-testid='series-occurrence']"

    view |> render() |> Floki.parse_document!() |> Floki.find(selector)
  end

  defp meetings(user) do
    Repo.all(
      from(m in MeetingSchema,
        where: m.organizer_user_id == ^user.id,
        order_by: m.start_time
      )
    )
  end

  defp clash(user, start) do
    insert(:meeting,
      organizer_user_id: user.id,
      start_time: start,
      end_time: DateTime.add(start, 30, :minute),
      status: :confirmed
    )
  end

  @tag :capture_log
  test "a booker books a weekly series of 4", %{conn: conn, day: day} do
    %{user: user, profile: profile} = organiser("series-weekly", @weekly)

    view = to_series(conn, profile, day)

    assert has_element?(view, "#series-step h1", "Book a series")
    assert has_element?(view, "[data-testid='series-rule']", "Every week")
    assert has_element?(view, "[data-testid='series-count']", "4 sessions")
    assert length(occurrences(view, "available")) == 4
    assert has_element?(view, "[data-testid='series-announcement']", "4 of 4 sessions available")

    BookingDriver.continue(view)
    assert has_element?(view, "#submit-booking-button", "Book 4 sessions")

    html = BookingDriver.submit(view, %{name: "Ada", email: "ada@example.com"})

    assert html =~ "4 sessions booked"

    assert length(
             Floki.find(Floki.parse_document!(html), "[data-testid='series-booked-session']")
           ) ==
             4

    assert has_element?(view, "[data-testid='series-manage']", "Manage all sessions")

    booked = meetings(user)
    assert length(booked) == 4
    assert Enum.map(booked, & &1.start_time) == Enum.map(0..3, &at_nine(day, &1))
    assert [series_id] = booked |> Enum.map(& &1.series_id) |> Enum.uniq()
    assert %SeriesSchema{id: ^series_id} = Repo.get!(SeriesSchema, series_id)
    assert Enum.map(booked, & &1.series_position) == [1, 2, 3, 4]
  end

  @tag :capture_log
  test "the whole walk books a series through the booking driver", %{conn: conn} do
    %{user: user, profile: profile} = organiser("series-driver", @weekly)

    {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=Etc/UTC")
    html = BookingDriver.book(view, attendee: %{name: "Walk", email: "walk@example.com"})

    assert html =~ "4 sessions booked"
    assert length(meetings(user)) == 4
  end

  @tag :capture_log
  test "a single booking after a series confirms only itself", %{conn: conn, day: day} do
    %{user: user, profile: profile} =
      organiser("series-then-single", Keyword.put(@weekly, :series_required, false))

    view = to_series(conn, profile, day)
    BookingDriver.continue(view)

    assert BookingDriver.submit(view, %{name: "Twice", email: "twice@example.com"}) =~
             "4 sessions booked"

    BookingDriver.restart(view)
    BookingDriver.choose_meeting_type(view, hd(BookingDriver.meeting_types(view)))
    {_iso, _time} = BookingDriver.pick_first_slot(view, on: Date.to_iso8601(Date.add(day, 1)))
    BookingDriver.continue(view)
    render_async(view)

    view |> element("[data-testid='series-book-single']") |> render_click()
    _sync = :sys.get_state(view.pid)

    html = BookingDriver.submit(view, %{name: "Twice", email: "twice@example.com"})

    assert html =~ "Meeting Confirmed!"
    refute html =~ "sessions booked"
    refute has_element?(view, "[data-testid='series-booked']")
    assert length(meetings(user)) == 5
  end

  @tag :capture_log
  test "the count stepper changes the list", %{conn: conn, day: day} do
    %{profile: profile} =
      organiser(
        "series-stepper",
        Keyword.merge(@weekly, series_min_occurrences: 2, series_max_occurrences: 6)
      )

    view = to_series(conn, profile, day)

    assert length(occurrences(view)) == 2
    assert has_element?(view, "[data-testid='series-count-less'][disabled]")

    view |> element("[data-testid='series-count-more']") |> render_click()
    render_async(view)
    view |> element("[data-testid='series-count-more']") |> render_click()
    render_async(view)

    assert has_element?(view, "[data-testid='series-count']", "4 sessions")
    assert length(occurrences(view, "available")) == 4

    view |> element("[data-testid='series-count-less']") |> render_click()
    render_async(view)

    assert length(occurrences(view, "available")) == 3
  end

  @tag :capture_log
  test "a clashing date blocks continue and names it", %{conn: conn, day: day} do
    %{user: user, profile: profile} = organiser("series-clash", @weekly)
    clash(user, at_nine(day, 1))

    view = to_series(conn, profile, day)

    assert [unavailable] = occurrences(view, "unavailable")
    assert Floki.attribute(unavailable, "id") == ["series-occurrence-2"]
    assert Floki.text(unavailable) =~ "Not available"
    assert has_element?(view, "[data-testid='series-unavailable']", "Pick another time")
    assert has_element?(view, "#series-step [data-intent='continue'][disabled]")
  end

  @tag :capture_log
  test "book just this session on an optional series", %{conn: conn, day: day} do
    %{user: user, profile: profile} =
      organiser("series-optional", Keyword.put(@weekly, :series_required, false))

    view = to_series(conn, profile, day)

    view |> element("[data-testid='series-book-single']") |> render_click()
    _sync = :sys.get_state(view.pid)

    assert has_element?(view, "form[data-fact='attendee']")
    refute has_element?(view, "[data-testid='booking-series-summary']")

    html = BookingDriver.submit(view, %{name: "Solo", email: "solo@example.com"})
    refute html =~ "sessions booked"

    assert [meeting] = meetings(user)
    assert meeting.series_id == nil
    assert meeting.start_time == at_nine(day, 0)
  end

  @tag :capture_log
  test "a series takes no guests, a single session does", %{conn: conn, day: day} do
    attrs = Keyword.merge(@weekly, allow_guests: true, series_required: false)
    %{profile: profile} = organiser("series-guests", attrs)

    view = to_series(conn, profile, day)
    BookingDriver.continue(view)
    assert has_element?(view, "form[data-fact='attendee']")
    refute has_element?(view, "[data-testid='guest-field']")

    view = to_series(conn, profile, day)
    view |> element("[data-testid='series-book-single']") |> render_click()
    _sync = :sys.get_state(view.pid)
    assert has_element?(view, "[data-testid='guest-field']")
  end

  @tag :capture_log
  test "a flexible series of 3 at different times", %{conn: conn, day: day} do
    %{user: user, profile: profile} =
      organiser("series-flexible",
        name: "Flexible Pack",
        duration_minutes: 30,
        series_mode: :flexible,
        series_min_occurrences: 3,
        series_max_occurrences: 3
      )

    view = to_series(conn, profile, day)

    assert has_element?(view, "#series-step h1", "Choose your 3 sessions")
    assert has_element?(view, "#series-step [data-intent='continue'][disabled]")

    add_last_time_of_day(view, 0)
    add_last_time_of_day(view, -1)

    assert length(occurrences(view, "available")) == 3
    refute has_element?(view, "[data-testid='series-add']")

    BookingDriver.continue(view)
    assert has_element?(view, "[data-testid='booking-series-summary']", "3 sessions, first on")

    html = BookingDriver.submit(view, %{name: "Flex", email: "flex@example.com"})
    assert html =~ "3 sessions booked"

    starts = user |> meetings() |> Enum.map(& &1.start_time)
    assert length(starts) == 3
    assert hd(starts) == at_nine(day, 0)
    assert starts |> Enum.map(&DateTime.to_time/1) |> Enum.uniq() |> length() > 1
  end

  # Opens the picker and adds the last free time of its `index`th day.
  defp add_last_time_of_day(view, index) do
    view |> element("[data-testid='series-add']") |> render_click()
    render_async(view)

    days =
      view
      |> render()
      |> Floki.parse_document!()
      |> Floki.find("[data-testid='series-picker-day']")
      |> Enum.flat_map(&Floki.attribute(&1, "data-date"))

    view
    |> element("[data-testid='series-picker-day'][data-date='#{Enum.at(days, index)}']")
    |> render_click()

    starts =
      view
      |> render()
      |> Floki.parse_document!()
      |> Floki.find("[data-testid='series-picker-time']")
      |> Enum.flat_map(&Floki.attribute(&1, "data-value"))

    view
    |> element("[data-testid='series-picker-time'][data-value='#{List.last(starts)}']")
    |> render_click()

    render_async(view)
  end

  @tag :capture_log
  test "a slot taken during submission returns to the series moment", %{conn: conn, day: day} do
    %{user: user, profile: profile} = organiser("series-race", @weekly)

    view = to_series(conn, profile, day)
    BookingDriver.continue(view)
    assert has_element?(view, "form[data-fact='attendee']")

    clash(user, at_nine(day, 2))
    AvailabilityCache.clear_all()

    BookingDriver.submit(view, %{name: "Late", email: "late@example.com"})
    render_async(view)

    assert has_element?(view, "#series-step")
    assert [lost] = occurrences(view, "unavailable")
    assert Floki.attribute(lost, "id") == ["series-occurrence-3"]
    assert has_element?(view, "[data-testid='series-unavailable']")

    assert [_the_clash] = meetings(user)
  end

  @tag :capture_log
  test "a paid series redirects to checkout", %{conn: conn, day: day} do
    %{user: user, profile: profile} =
      organiser(
        "series-paid",
        Keyword.merge(@weekly, payment_required: true, price_cents: 5000)
      )

    insert(:connect_account,
      user: user,
      stripe_account_id: "acct_SERIES",
      default_currency: "usd",
      charges_enabled: true
    )

    StripeStub.expect(
      :create_checkout_session,
      1,
      StripeStubResponses.checkout_session("cs_SERIES", @checkout_url)
    )

    view = to_series(conn, profile, day)
    assert has_element?(view, "[data-testid='series-total']", "200")

    BookingDriver.continue(view)

    view
    |> form("form[data-fact='attendee']", %{
      "booking" => %{"name" => "Pay", "email" => "pay@example.com", "message" => ""}
    })
    |> render_submit()

    assert_redirect(view, @checkout_url, 5_000)
    assert [%{form: form}] = StripeStub.requests(:create_checkout_session)

    assert [%{"price_data" => %{"unit_amount" => "5000"}, "quantity" => "4"}] =
             form["line_items"]

    assert user |> meetings() |> Enum.map(& &1.status) == List.duplicate(:awaiting_payment, 4)
  end

  @tag :capture_log
  test "a host without access shows the single-session flow", %{conn: conn, day: day} do
    setup_config(:tymeslot, feature_access_checker: DenyChecker)
    %{user: user, profile: profile} = organiser("series-denied", @weekly)

    {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=Etc/UTC")
    BookingDriver.choose_meeting_type(view, hd(BookingDriver.meeting_types(view)))
    {_iso, _time} = BookingDriver.pick_first_slot(view, on: Date.to_iso8601(day))
    BookingDriver.continue(view)

    refute has_element?(view, "#series-step")
    assert has_element?(view, "form[data-fact='attendee']")

    html = BookingDriver.submit(view, %{name: "Plain", email: "plain@example.com"})
    refute html =~ "sessions booked"

    assert [meeting] = meetings(user)
    assert meeting.series_id == nil
  end

  @tag :capture_log
  test "an approval series confirms with the request wording", %{conn: conn, day: day} do
    %{user: user, profile: profile} =
      organiser(
        "series-approval",
        Keyword.merge(@weekly, requires_approval: true, approval_window_hours: 24)
      )

    view = to_series(conn, profile, day)
    BookingDriver.continue(view)
    html = BookingDriver.submit(view, %{name: "Ask", email: "ask@example.com"})

    assert html =~ "Your request for 4 sessions has been sent"

    assert length(
             Floki.find(Floki.parse_document!(html), "[data-testid='series-booked-session']")
           ) == 4

    assert user |> meetings() |> Enum.map(& &1.status) ==
             List.duplicate(:awaiting_approval, 4)
  end

  describe "with the host's calendar failing on cue" do
    setup do
      {:ok, calendar} = Agent.start_link(fn -> :up end)

      stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
        case Agent.get(calendar, & &1) do
          :up -> {:ok, []}
          :down -> {:error, :timeout}
        end
      end)

      %{calendar: calendar}
    end

    @tag :capture_log
    test "an unverifiable check says so and its retry checks again",
         %{conn: conn, day: day, calendar: calendar} do
      %{profile: profile} = organiser("series-unverifiable", @weekly)

      {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=Etc/UTC")
      BookingDriver.choose_meeting_type(view, hd(BookingDriver.meeting_types(view)))
      {_iso, _time} = BookingDriver.pick_first_slot(view, on: Date.to_iso8601(day))

      Agent.update(calendar, fn _state -> :down end)
      AvailabilityCache.clear_all()
      BookingDriver.continue(view)
      render_async(view)

      assert has_element?(view, "[data-testid='series-check-error']", "couldn't check")
      assert has_element?(view, "#series-step [data-intent='continue'][disabled]")

      Agent.update(calendar, fn _state -> :up end)
      view |> element("[data-testid='series-retry']") |> render_click()
      render_async(view)

      refute has_element?(view, "[data-testid='series-check-error']")
      assert length(occurrences(view, "available")) == 4
      assert has_element?(view, "#series-step [data-intent='continue']:not([disabled])")
    end

    @tag :capture_log
    test "a picker week that failed to load loads again on retry",
         %{conn: conn, day: day, calendar: calendar} do
      %{profile: profile} = organiser("series-picker-retry", @flexible)

      view = to_series(conn, profile, day)

      Agent.update(calendar, fn _state -> :down end)
      view |> element("[data-testid='series-add']") |> render_click()
      render_async(view)

      assert has_element?(
               view,
               "[data-testid='series-picker'] [data-testid='series-check-error']"
             )

      refute has_element?(view, "[data-testid='series-picker-time']")

      Agent.update(calendar, fn _state -> :up end)
      view |> element("[data-testid='series-picker-retry']") |> render_click()
      render_async(view)

      refute has_element?(
               view,
               "[data-testid='series-picker'] [data-testid='series-check-error']"
             )

      assert has_element?(view, "[data-testid='series-picker-time']")
    end
  end

  @tag :capture_log
  test "the picker offers sessions past the booking window", %{conn: conn, day: day} do
    %{profile: profile} = organiser("series-far", @flexible)

    view = to_series(conn, profile, day)
    view |> element("[data-testid='series-add']") |> render_click()
    render_async(view)

    for _week <- 1..6 do
      view |> element("[data-testid='series-picker-later']") |> render_click()
      render_async(view)
    end

    window_end = Date.add(Date.utc_today(), 30)

    far_days =
      view
      |> render()
      |> Floki.parse_document!()
      |> Floki.find("[data-testid='series-picker-day']")
      |> Enum.flat_map(&Floki.attribute(&1, "data-date"))
      |> Enum.filter(&(Date.compare(Date.from_iso8601!(&1), window_end) == :gt))

    assert far_days != []
    assert has_element?(view, "[data-testid='series-picker-time']")
  end

  @tag :capture_log
  test "a session added can be removed again, and the focus returns to adding",
       %{conn: conn, day: day} do
    %{profile: profile} = organiser("series-remove", @flexible)

    view = to_series(conn, profile, day)
    add_last_time_of_day(view, 0)

    assert length(occurrences(view)) == 2
    assert has_element?(view, "#series-add[phx-mounted]")

    [added] =
      view
      |> render()
      |> Floki.parse_document!()
      |> Floki.find("[data-testid='series-remove']")

    [start] = Floki.attribute(added, "phx-value-start")

    view |> element("[data-testid='series-remove'][phx-value-start='#{start}']") |> render_click()
    render_async(view)

    assert length(occurrences(view)) == 1
    refute has_element?(view, "[data-testid='series-remove']")
  end
end
