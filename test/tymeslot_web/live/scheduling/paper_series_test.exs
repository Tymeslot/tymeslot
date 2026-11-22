defmodule TymeslotWeb.Live.Scheduling.PaperSeriesTest do
  @moduledoc """
  Booking a series on the Paper theme, end to end: the booker picks a time,
  which is the first session, and the series opens below it on the same
  screen; once every session is available the details follow below the
  series, and the booker lands on a confirmation listing every session.
  Mocked are the boundaries only: the calendar provider and Stripe.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :scheduling
  @moduletag :live

  import Tymeslot.Factory
  import TymeslotWeb.SeriesBookingHelpers

  alias Tymeslot.StripeStub
  alias Tymeslot.StripeStubResponses
  alias TymeslotWeb.BookingDriver

  @theme "3"
  @flow [reveal: true]
  @checkout_url "https://checkout.stripe.com/c/pay/cs_PAPER_SERIES"

  setup tags, do: setup_series(tags)

  @tag :capture_log
  test "Paper: a booker books a weekly series of 4", %{conn: conn, day: day} do
    %{user: user, profile: profile} = organiser(@theme, "paper-weekly", weekly())

    view = to_series(conn, profile, day, @flow)

    assert has_element?(view, "[data-testid='series-step']", "Book a series")
    assert has_element?(view, "[data-testid='series-rule']", "Every week")
    assert has_element?(view, "[data-testid='series-count']", "4 sessions")
    assert length(occurrences(view, "available")) == 4

    to_details(view, @flow)
    assert has_element?(view, "[data-testid='booking-series-summary']", "4 sessions, first on")
    assert has_element?(view, "[data-intent='submit']", "Book 4 sessions")

    html = BookingDriver.submit(view, %{name: "Ada", email: "ada@example.com"})
    assert html =~ "4 sessions booked"

    booked = meetings(user)
    assert Enum.map(booked, & &1.start_time) == Enum.map(0..3, &at_nine(day, &1))
    assert [_one_series] = booked |> Enum.map(& &1.series_id) |> Enum.uniq()
  end

  @tag :capture_log
  test "Paper: another time picked remakes the series from it", %{conn: conn, day: day} do
    %{user: user, profile: profile} = organiser(@theme, "paper-retime", weekly())

    view = to_series(conn, profile, day, @flow)
    to_details(view, @flow)

    # Another time on the same day: the day stays picked, so only the
    # series below can notice the change.
    [_nine, later | _rest] = free_times(view)
    BookingDriver.pick_time(view, later)
    render_async(view)

    assert length(occurrences(view, "available")) == 4
    to_details(view, @flow)
    BookingDriver.submit(view, %{name: "Ada", email: "ada@example.com"})

    starts = user |> meetings() |> Enum.map(& &1.start_time)
    first = hd(starts)

    assert DateTime.to_date(first) == day
    assert DateTime.to_time(first) != ~T[09:00:00]
    assert starts == Enum.map(0..3, &DateTime.add(first, &1 * 7, :day))
  end

  # "Change time" stays on the screen: it brings the picker back and takes
  # the focus to the time picked, a browser-side command with nothing to
  # send, so its command and its target are what is asserted.
  @tag :capture_log
  test "Paper: change time on a clash goes to the time picked", %{conn: conn, day: day} do
    %{user: user, profile: profile} = organiser(@theme, "paper-change", weekly())
    clash(user, at_nine(day, 1))

    view = to_series(conn, profile, day, @flow)

    commands = change_time_commands(view)

    assert ["remove_class", %{"names" => ["paper-card--booking"], "to" => "#schedule-step"}] in commands

    assert [["focus", %{"to" => to}]] = Enum.filter(commands, &match?(["focus", _options], &1))
    assert to =~ "#schedule-step .slot-list__slot--selected"
    refute Enum.any?(commands, &match?(["push", _options], &1))

    assert has_element?(view, "#schedule-step .slot-list__slot--selected")
  end

  @tag :capture_log
  test "Paper: just this session names the time once", %{conn: conn, day: day} do
    %{profile: profile} =
      organiser(@theme, "paper-single", Keyword.put(weekly(), :series_required, false))

    view = to_series(conn, profile, day, @flow)
    view |> element("[data-testid='series-book-single']") |> render_click()
    _sync = :sys.get_state(view.pid)

    assert has_element?(view, "form[data-fact='attendee']")
    assert [_one] = find(view, "[data-testid='paper-change-time']")
    refute has_element?(view, "[data-testid='paper-book-when']")
  end

  @tag :capture_log
  test "Paper: another count keeps the details while it is checked", %{conn: conn, day: day} do
    %{user: user, profile: profile} =
      organiser(
        @theme,
        "paper-recount",
        Keyword.merge(weekly(), series_min_occurrences: 2, series_max_occurrences: 4)
      )

    view = to_series(conn, profile, day, @flow)
    to_details(view, @flow)

    BookingDriver.fill_attendee(view, %{name: "Ada", email: "ada@example.com"})
    assert has_element?(view, "[data-intent='submit']:not([disabled])")

    gate = hold_calendar()
    view |> element("[data-testid='series-count-more']") |> render_click()
    assert_receive {:calendar_held, _check}, 5_000

    assert has_element?(view, "form[data-fact='attendee']")
    assert has_element?(view, "[data-intent='submit'][disabled]")

    release_calendar(gate)
    render_async(view)
    assert has_element?(view, "[data-intent='submit']:not([disabled])", "Book 3 sessions")

    BookingDriver.submit(view, %{name: "Ada", email: "ada@example.com"})
    assert length(meetings(user)) == 3
  end

  @tag :capture_log
  test "Paper: a clashing date blocks continue", %{conn: conn, day: day} do
    %{user: user, profile: profile} = organiser(@theme, "paper-clash", weekly())
    clash(user, at_nine(day, 1))

    view = to_series(conn, profile, day, @flow)

    assert [unavailable] = occurrences(view, "unavailable")
    assert Floki.attribute(unavailable, "id") == ["series-occurrence-2"]
    assert has_element?(view, "[data-testid='series-unavailable']", "Pick another time")
    refute has_element?(view, "form[data-fact='attendee']")
  end

  @tag :capture_log
  test "Paper: a flexible series", %{conn: conn, day: day} do
    %{user: user, profile: profile} = organiser(@theme, "paper-flexible", flexible())

    view = to_series(conn, profile, day, @flow)

    assert has_element?(view, "[data-testid='series-step']", "Choose your 3 sessions")
    refute has_element?(view, "form[data-fact='attendee']")

    add_last_time_of_day(view, 0)
    add_last_time_of_day(view, -1)
    assert length(occurrences(view, "available")) == 3

    to_details(view, @flow)
    html = BookingDriver.submit(view, %{name: "Flex", email: "flex@example.com"})
    assert html =~ "3 sessions booked"

    starts = user |> meetings() |> Enum.map(& &1.start_time)
    assert hd(starts) == at_nine(day, 0)
    assert length(starts) == 3
    assert starts |> Enum.map(&DateTime.to_time/1) |> Enum.uniq() |> length() > 1
  end

  @tag :capture_log
  test "Paper: a series takes no guests, a single session does", %{conn: conn, day: day} do
    attrs = Keyword.merge(weekly(), allow_guests: true, series_required: false)
    %{profile: profile} = organiser(@theme, "paper-guests", attrs)

    view = to_series(conn, profile, day, @flow)
    to_details(view, @flow)
    refute has_element?(view, "[data-testid='guest-field']")

    view = to_series(conn, profile, day, @flow)
    view |> element("[data-testid='series-book-single']") |> render_click()
    to_details(view, reveal: true)
    assert has_element?(view, "[data-testid='guest-field']")
  end

  @tag :capture_log
  test "Paper: a paid series redirects to checkout", %{conn: conn, day: day} do
    %{user: user, profile: profile} =
      organiser(
        @theme,
        "paper-paid",
        Keyword.merge(weekly(), payment_required: true, price_cents: 5000)
      )

    insert(:connect_account,
      user: user,
      stripe_account_id: "acct_PAPER_SERIES",
      default_currency: "usd",
      charges_enabled: true
    )

    StripeStub.expect(
      :create_checkout_session,
      1,
      StripeStubResponses.checkout_session("cs_PAPER_SERIES", @checkout_url)
    )

    view = to_series(conn, profile, day, @flow)
    assert has_element?(view, "[data-testid='series-total']", "200")

    to_details(view, @flow)
    assert has_element?(view, "[data-testid='series-total']", "200")

    view
    |> form("form[data-fact='attendee']", %{
      "booking" => %{"name" => "Pay", "email" => "pay@example.com", "message" => ""}
    })
    |> render_submit()

    assert_redirect(view, @checkout_url, 5_000)
    assert [%{form: form}] = StripeStub.requests(:create_checkout_session)

    assert [%{"price_data" => %{"unit_amount" => "5000"}, "quantity" => "4"}] =
             form["line_items"]
  end

  @tag :capture_log
  test "Paper: confirmation lists every session", %{conn: conn, day: day} do
    %{profile: profile} = organiser(@theme, "paper-confirmed", weekly())

    view = to_series(conn, profile, day, @flow)
    to_details(view, @flow)
    html = BookingDriver.submit(view, %{name: "Ada", email: "ada@example.com"})

    assert length(booked_sessions(html)) == 4
    assert has_element?(view, "[data-testid='series-booked-session'] a", "Reschedule")
    assert has_element?(view, "[data-testid='series-manage']", "Manage all sessions")
    refute has_element?(view, "[data-testid='add-to-calendar']")
  end

  @tag :capture_log
  test "Paper: an approval series is requested and confirmed as a request",
       %{conn: conn, day: day} do
    %{user: user, profile: profile} =
      organiser(
        @theme,
        "paper-approval",
        Keyword.merge(weekly(), requires_approval: true, approval_window_hours: 24)
      )

    view = to_series(conn, profile, day, @flow)
    to_details(view, @flow)
    assert has_element?(view, "[data-intent='submit']", "Request 4 sessions")

    html = BookingDriver.submit(view, %{name: "Ask", email: "ask@example.com"})

    assert html =~ "Your request for 4 sessions has been sent"
    assert length(booked_sessions(html)) == 4
    assert user |> meetings() |> Enum.map(& &1.status) == List.duplicate(:awaiting_approval, 4)
  end

  @tag :capture_log
  test "Paper: the booking driver's whole walk books a series", %{conn: conn} do
    %{user: user, profile: profile} = organiser(@theme, "paper-driver", weekly())

    {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=Etc/UTC")
    html = BookingDriver.book(view, attendee: %{name: "Walk", email: "walk@example.com"})

    assert html =~ "4 sessions booked"
    assert length(meetings(user)) == 4
  end

  defp free_times(view) do
    view
    |> render()
    |> Floki.parse_document!()
    |> Floki.find("[data-fact='time']:not([data-alternate])")
    |> Enum.flat_map(&Floki.attribute(&1, "data-value"))
  end

  defp change_time_commands(view) do
    [command] =
      view
      |> render()
      |> Floki.parse_document!()
      |> Floki.attribute("[data-testid='series-change-time']", "phx-click")

    Jason.decode!(command)
  end

  defp find(view, selector),
    do: view |> render() |> Floki.parse_document!() |> Floki.find(selector)
end
