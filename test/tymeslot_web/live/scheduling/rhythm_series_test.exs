defmodule TymeslotWeb.Live.Scheduling.RhythmSeriesTest do
  @moduledoc """
  Booking a series on the Rhythm theme, end to end: the booker picks a time,
  which is the first session, chooses the series on Rhythm's series slide,
  moves on to the form and lands on a confirmation listing every session.
  Mocked are the boundaries only: the calendar provider and Stripe.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :scheduling
  @moduletag :live

  import Mox
  import Tymeslot.Factory
  import TymeslotWeb.SeriesBookingHelpers

  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias TymeslotWeb.BookingDriver

  @theme "2"
  @flow [reveal: false]
  @checkout_url "https://checkout.stripe.com/c/pay/cs_RHYTHM_SERIES"

  setup :verify_on_exit!
  setup tags, do: setup_series(tags)

  @tag :capture_log
  test "Rhythm: a booker books a weekly series of 4", %{conn: conn, day: day} do
    %{user: user, profile: profile} = organiser(@theme, "rhythm-weekly", weekly())

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
  test "Rhythm: change time on a clash goes back to the times", %{conn: conn, day: day} do
    %{user: user, profile: profile} = organiser(@theme, "rhythm-change", weekly())
    clash(user, at_nine(day, 1))

    view = to_series(conn, profile, day, @flow)
    view |> element("[data-testid='series-change-time']") |> render_click()
    _sync = :sys.get_state(view.pid)

    assert has_element?(view, "#schedule-step [data-fact='time']")
    refute has_element?(view, "[data-testid='series-step']")
  end

  @tag :capture_log
  test "Rhythm: a clashing date blocks continue", %{conn: conn, day: day} do
    %{user: user, profile: profile} = organiser(@theme, "rhythm-clash", weekly())
    clash(user, at_nine(day, 1))

    view = to_series(conn, profile, day, @flow)

    assert [unavailable] = occurrences(view, "unavailable")
    assert Floki.attribute(unavailable, "id") == ["series-occurrence-2"]
    assert has_element?(view, "[data-testid='series-unavailable']", "Pick another time")
    assert has_element?(view, "[data-testid='series-step'] [data-intent='continue'][disabled]")
    refute has_element?(view, "form[data-fact='attendee']")
  end

  @tag :capture_log
  test "Rhythm: a flexible series", %{conn: conn, day: day} do
    %{user: user, profile: profile} = organiser(@theme, "rhythm-flexible", flexible())

    view = to_series(conn, profile, day, @flow)

    assert has_element?(view, "[data-testid='series-step']", "Choose your 3 sessions")
    assert has_element?(view, "[data-testid='series-step'] [data-intent='continue'][disabled]")

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
  test "Rhythm: a series takes no guests, a single session does", %{conn: conn, day: day} do
    attrs = Keyword.merge(weekly(), allow_guests: true, series_required: false)
    %{profile: profile} = organiser(@theme, "rhythm-guests", attrs)

    view = to_series(conn, profile, day, @flow)
    to_details(view, @flow)
    refute has_element?(view, "[data-testid='guest-field']")

    view = to_series(conn, profile, day, @flow)
    view |> element("[data-testid='series-book-single']") |> render_click()
    to_details(view, reveal: true)
    assert has_element?(view, "[data-testid='guest-field']")
  end

  @tag :capture_log
  test "Rhythm: a paid series redirects to checkout", %{conn: conn, day: day} do
    %{user: user, profile: profile} =
      organiser(
        @theme,
        "rhythm-paid",
        Keyword.merge(weekly(), payment_required: true, price_cents: 5000)
      )

    insert(:connect_account,
      user: user,
      stripe_account_id: "acct_RHYTHM_SERIES",
      default_currency: "usd",
      charges_enabled: true
    )

    test_pid = self()

    expect(StripeAdapterMock, :create_checkout_session, fn params, _opts ->
      send(test_pid, {:checkout_session, params})
      {:ok, %{id: "cs_RHYTHM_SERIES", url: @checkout_url}}
    end)

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
    assert_received {:checkout_session, params}
    assert [%{price_data: %{unit_amount: 5000}, quantity: 4}] = params.line_items
  end

  @tag :capture_log
  test "Rhythm: confirmation lists every session", %{conn: conn, day: day} do
    %{profile: profile} = organiser(@theme, "rhythm-confirmed", weekly())

    view = to_series(conn, profile, day, @flow)
    to_details(view, @flow)
    html = BookingDriver.submit(view, %{name: "Ada", email: "ada@example.com"})

    assert length(booked_sessions(html)) == 4
    assert has_element?(view, "[data-testid='series-booked-session'] a", "Reschedule")
    assert has_element?(view, "[data-testid='series-manage']", "Manage all sessions")
    refute has_element?(view, "[data-testid='add-to-calendar']")
  end

  @tag :capture_log
  test "Rhythm: an approval series is requested and confirmed as a request",
       %{conn: conn, day: day} do
    %{user: user, profile: profile} =
      organiser(
        @theme,
        "rhythm-approval",
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
  test "Rhythm: the booking driver's whole walk books a series", %{conn: conn} do
    %{user: user, profile: profile} = organiser(@theme, "rhythm-driver", weekly())

    {:ok, view, _html} = live(conn, "/#{profile.username}?timezone=Etc/UTC")
    html = BookingDriver.book(view, attendee: %{name: "Walk", email: "walk@example.com"})

    assert html =~ "4 sessions booked"
    assert length(meetings(user)) == 4
  end
end
