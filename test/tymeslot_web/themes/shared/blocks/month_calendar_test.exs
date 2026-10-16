defmodule TymeslotWeb.Themes.Shared.Blocks.MonthCalendarTest do
  @moduledoc """
  The month of days a theme picks a date from. The days are passed in (the
  shape `CalendarHelpers.get_calendar_days/7` returns), so the block is
  pinned apart from the availability rules: which days are buttons for the
  date fact, which are disabled, and the month navigation's bounds. The clock
  is frozen on Wednesday 10 March 2027.
  """
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :components

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Tymeslot.Test.ClockHelpers
  alias TymeslotWeb.Themes.Shared.Blocks.MonthCalendar

  @days [
    %{
      date: "2027-02-28",
      day: 28,
      available: false,
      loading: false,
      past: true,
      today: false,
      current_month: false
    },
    %{
      date: "2027-03-09",
      day: 9,
      available: true,
      loading: false,
      past: true,
      today: false,
      current_month: true
    },
    %{
      date: "2027-03-10",
      day: 10,
      available: true,
      loading: false,
      past: false,
      today: true,
      current_month: true
    },
    %{
      date: "2027-03-11",
      day: 11,
      available: false,
      loading: false,
      past: false,
      today: false,
      current_month: true
    },
    %{
      date: "2027-03-12",
      day: 12,
      available: true,
      loading: false,
      past: false,
      today: false,
      current_month: true
    }
  ]

  setup do
    Gettext.put_locale(TymeslotWeb.Gettext, "en")
    ClockHelpers.freeze_clock(~U[2027-03-10 12:00:00Z])
    :ok
  end

  defp render_calendar(overrides \\ []) do
    assigns =
      Map.merge(
        %{
          current_year: 2027,
          current_month: 3,
          user_timezone: "Etc/UTC",
          first_day: :monday,
          booking_window_days: 90,
          days: @days,
          target: nil
        },
        Map.new(overrides)
      )

    (&MonthCalendar.month_calendar/1)
    |> render_component(assigns)
    |> Floki.parse_fragment!()
  end

  defp enabled_dates(doc),
    do: Floki.attribute(doc, "[data-fact=date]:not([disabled])", "data-value")

  test "offers each free day of the month from today on as a date fact" do
    doc = render_calendar()

    assert enabled_dates(doc) == ["2027-03-10", "2027-03-12"]
    assert Floki.attribute(doc, "[data-value='2027-03-12']", "phx-click") == ["select_date"]
    assert Floki.attribute(doc, "[data-value='2027-03-12']", "phx-value-date") == ["2027-03-12"]
    assert Floki.attribute(doc, "[data-value='2027-03-12']", "data-testid") == ["calendar-day"]
  end

  test "names each day by its full date and marks today and the chosen day" do
    doc = render_calendar(selected_date: "2027-03-12")

    assert Floki.attribute(doc, "[data-value='2027-03-10']", "aria-current") == ["date"]
    assert Floki.attribute(doc, "[data-value='2027-03-12']", "aria-pressed") == ["true"]
    assert Floki.attribute(doc, "[data-value='2027-03-10']", "aria-pressed") == ["false"]

    assert Floki.attribute(doc, "[data-value='2027-03-12']", "aria-label") == [
             "Friday, 12 March 2027"
           ]
  end

  test "heads the days with the month and seven weekdays" do
    doc = render_calendar()

    assert doc |> Floki.find(".month-calendar__title") |> Floki.text() |> String.trim() ==
             "March 2027"

    assert length(Floki.find(doc, ".month-calendar__weekday")) == 7
  end

  test "starts the weekday headings on the week's first day" do
    weekdays = fn doc ->
      doc |> Floki.find(".month-calendar__weekday") |> Enum.map(&String.trim(Floki.text(&1)))
    end

    assert weekdays.(render_calendar(first_day: :monday)) == ~w(Mon Tue Wed Thu Fri Sat Sun)
    assert weekdays.(render_calendar(first_day: :sunday)) == ~w(Sun Mon Tue Wed Thu Fri Sat)
  end

  test "goes back no further than the current month, and forward to the booking window's end" do
    doc = render_calendar(booking_window_days: 90)

    assert Floki.attribute(doc, "[data-testid=month-calendar-prev]", "disabled") != []
    assert Floki.attribute(doc, "[data-testid=month-calendar-next]", "disabled") == []

    assert Floki.attribute(doc, "[data-testid=month-calendar-next]", "aria-label") == [
             "Next month"
           ]

    short = render_calendar(booking_window_days: 10)
    assert Floki.attribute(short, "[data-testid=month-calendar-next]", "disabled") != []
  end

  test "marks the month controls as the period arrows of the markup contract" do
    doc = render_calendar()

    assert Floki.attribute(doc, "[data-testid=month-calendar-prev]", "data-intent") == ["earlier"]
    assert Floki.attribute(doc, "[data-testid=month-calendar-next]", "data-intent") == ["later"]
    assert length(Floki.find(doc, "[data-intent=earlier]")) == 1
    assert length(Floki.find(doc, "[data-intent=later]")) == 1
  end

  test "gives a padded day of the neighbouring month no fact" do
    doc = render_calendar()

    assert [_padded] = Floki.find(doc, ".month-calendar__day--other-month")
    assert Floki.attribute(doc, ".month-calendar__day--other-month", "data-fact") == []
    assert Floki.attribute(doc, ".month-calendar__day--other-month", "data-value") == []
    assert Floki.find(doc, "[data-value='2027-02-28']") == []
    assert length(Floki.find(doc, "[data-fact=date]")) == 4
  end

  test "says so when the month's availability could not be loaded" do
    assert render_calendar(availability_status: :error)
           |> Floki.find(".month-calendar__notice")
           |> Floki.text() =~ "Calendar is loading slowly"

    assert Floki.find(render_calendar(), ".month-calendar__notice") == []
  end
end
