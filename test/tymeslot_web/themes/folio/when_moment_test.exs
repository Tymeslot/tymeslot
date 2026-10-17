defmodule TymeslotWeb.Themes.Folio.WhenMomentTest do
  @moduledoc """
  Folio's time section rendered alone: a fully booked month says so and
  offers the way to the first free day the page landed on, and says there
  are no free times when it landed on none.
  """
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :components

  import Phoenix.LiveViewTest, only: [render_component: 2]
  import Tymeslot.Factory

  alias TymeslotWeb.Themes.Folio.Scheduling.Components.WhenMoment

  setup do
    Gettext.put_locale(TymeslotWeb.Gettext, "en")
    :ok
  end

  # March 2030 on show with nothing free in it.
  defp when_moment(overrides) do
    assigns =
      Map.merge(
        %{
          id: "when-step",
          moment: :when,
          moment_state: :current,
          locale: "en",
          organizer_profile: build(:profile, full_name: "Mia Laurent", username: "mia"),
          meeting_type:
            build(:meeting_type, name: "Quick Chat", slug: "quick-chat", duration_minutes: 30),
          user_timezone: "Etc/UTC",
          current_year: 2030,
          current_month: 3,
          week_start: :monday,
          booking_window_days: 90,
          month_availability_map: %{},
          availability_status: :loaded,
          calendar_landing: nil,
          selected_date: nil,
          selected_time: nil,
          available_slots: [],
          loading_slots: false,
          calendar_error: nil,
          slot_interval_minutes: 30,
          duration_minutes: 30,
          expanded_hour: nil,
          timezone_dropdown_open: false,
          timezone_search: ""
        },
        Map.new(overrides)
      )

    WhenMoment |> render_component(assigns) |> Floki.parse_fragment!()
  end

  defp text(doc, selector),
    do: doc |> Floki.find(selector) |> Floki.text() |> String.split() |> Enum.join(" ")

  test "a fully booked month offers the first free day elsewhere" do
    landing = %{
      current_year: 2030,
      current_month: 4,
      current_week_start: ~D[2030-04-01],
      selected_date: "2030-04-02"
    }

    doc = when_moment(calendar_landing: landing)

    assert text(doc, "[data-testid='folio-month-empty'] p") == "I'm fully booked this month."
    assert [button] = Floki.find(doc, "[data-testid='folio-next-free-day']")
    assert Floki.attribute(button, "class") == ["folio-button folio-button--secondary"]

    # One click: back to the landing's month, its day selected, then the focus
    # on the month heading, which the re-render leaves in place.
    assert [click] = Floki.attribute(button, "phx-click")
    assert [["push", %{"event" => "first_available_week"}] | rest] = Jason.decode!(click)

    assert [
             ["push", %{"event" => "select_date", "value" => %{"date" => "2030-04-02"}}],
             ["focus", %{"to" => "#folio-calendar-month"}]
           ] = rest

    assert [heading] = Floki.find(doc, "#folio-calendar-month")
    assert Floki.attribute(heading, "tabindex") == ["-1"]
  end

  # The times load after the heading takes the focus; on a phone their own
  # scroll would carry the page past the heading the focus brought up.
  test "the times leave the view to the heading" do
    doc = when_moment(selected_date: "2030-03-12", available_slots: ["9:00 AM"])

    assert Floki.attribute(doc, "#slots-container", "data-auto-scroll") == ["off"]
  end

  # With the slot list's own scroll off, a day picked on a phone brings its
  # times into view through the click itself.
  test "a day's click brings the times heading into view" do
    doc = when_moment(selected_date: "2030-03-12", available_slots: ["9:00 AM"])

    assert [day | _later_days] = Floki.find(doc, "[data-fact='date']")
    assert Floki.attribute(day, "phx-value-date") == ["2030-03-01"]
    assert [click] = Floki.attribute(day, "phx-click")

    assert [
             ["push", %{"event" => "select_date", "target" => _target}],
             ["dispatch", %{"event" => "tymeslot:reveal", "to" => to}]
           ] = Jason.decode!(click)

    assert [_heading] = Floki.find(doc, to)
  end

  test "an empty month is a neutral notice, the slow-load line keeps the warning style" do
    doc = when_moment(availability_status: :error)

    assert [_notice] =
             Floki.find(doc, "[data-testid='folio-month-empty'].folio-calendar__notice--empty")

    assert [slow] = Floki.find(doc, "p.folio-calendar__notice")
    refute "folio-calendar__notice--empty" in String.split(hd(Floki.attribute(slow, "class")))
  end

  test "a month booked out before the window ends says only that it is fully booked" do
    # The month on show is this one: the booking window reaches into the next,
    # which the page did not land on (a `?date=` link, a language switch), so
    # nothing here says the whole window is empty.
    today = Date.utc_today()

    doc = when_moment(current_year: today.year, current_month: today.month)

    assert text(doc, "[data-testid='folio-month-empty']") == "I'm fully booked this month."
    assert Floki.find(doc, "[data-testid='folio-next-free-day']") == []
  end

  test "a landing in the month on show offers no way to another month" do
    landing = %{
      current_year: 2030,
      current_month: 3,
      current_week_start: ~D[2030-03-04],
      selected_date: "2030-03-05"
    }

    doc = when_moment(calendar_landing: landing)

    assert text(doc, "[data-testid='folio-month-empty']") == "I have no free times at the moment."
    assert Floki.find(doc, "[data-testid='folio-next-free-day']") == []
  end

  test "says nothing of the kind while the month has a free day" do
    doc = when_moment(month_availability_map: %{"2030-03-20" => true})

    assert Floki.find(doc, "[data-testid='folio-month-empty']") == []
  end

  test "with no free day anywhere, says there are no free times and offers no way" do
    doc = when_moment(calendar_landing: nil)

    assert text(doc, "[data-testid='folio-month-empty']") == "I have no free times at the moment."
    assert Floki.find(doc, "[data-testid='folio-next-free-day']") == []
  end
end
