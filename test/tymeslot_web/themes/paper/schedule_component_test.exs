defmodule TymeslotWeb.Themes.Paper.ScheduleComponentTest do
  @moduledoc """
  Paper's schedule screen rendered alone, in each calendar view: the month
  calendar for a month, or no setting at all; the shared week grid, its
  times once the week is in, for a week; and the week's actions bar naming
  the chosen day and time beside Back, with no Next.
  """
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :components

  import Phoenix.LiveViewTest, only: [render_component: 2]
  import Tymeslot.Factory

  alias Tymeslot.ThemeCustomizations.Tokens
  alias TymeslotWeb.Themes.Paper.Scheduling.Components.ScheduleComponent

  @monday ~D[2030-03-04]
  @wednesday "2030-03-06"

  setup do
    Gettext.put_locale(TymeslotWeb.Gettext, "en")
    :ok
  end

  defp tokens(view), do: %Tokens{media: %{calendar_view: view}}

  defp schedule(overrides) do
    assigns =
      Map.merge(
        %{
          id: "paper-schedule",
          locale: "en",
          current_state: :schedule,
          theme_tokens: nil,
          organizer_profile: build(:profile, full_name: "Ada Lovelace", username: "ada"),
          meeting_type:
            build(:meeting_type, name: "Quick Chat", slug: "quick-chat", duration_minutes: 30),
          host_currency: nil,
          user_timezone: "Etc/UTC",
          current_year: 2030,
          current_month: 3,
          current_week_start: @monday,
          week_start: :monday,
          calendar_today: @monday,
          booking_window_days: 90,
          month_availability_map: %{},
          availability_status: :loaded,
          selected_date: nil,
          selected_time: nil,
          available_slots: [],
          loading_slots: false,
          calendar_error: nil,
          slot_interval_minutes: 30,
          duration_minutes: 30,
          expanded_hour: nil,
          timezone_dropdown_open: false,
          timezone_search: "",
          week_slots: nil,
          week_slots_loading: false,
          week_slots_error: nil,
          entered_via_overview: true,
          moment: :schedule,
          moment_state: :current,
          engine: nil,
          form: nil,
          submitting: false
        },
        Map.new(overrides)
      )

    ScheduleComponent |> render_component(assigns) |> Floki.parse_fragment!()
  end

  defp week_slots, do: %{@wednesday => ["10:00 AM", "2:00 PM"]}

  defp text(doc, selector), do: doc |> Floki.find(selector) |> Floki.text() |> String.trim()

  describe "the month view" do
    for {label, tokens} <- [
          {"no tokens", nil},
          {"no calendar view resolved", %Tokens{media: %{}}},
          {"a month", %Tokens{media: %{calendar_view: "month"}}}
        ] do
      test "is the step for #{label}" do
        doc = schedule(theme_tokens: unquote(Macro.escape(tokens)), week_slots: week_slots())

        assert [_section] = Floki.find(doc, "section.paper-card[data-calendar-view='month']")
        assert Floki.find(doc, ".paper-card--week") == []
        assert length(Floki.find(doc, "button[data-testid='calendar-day']")) >= 28
        assert Floki.find(doc, "[data-testid='week-grid']") == []
        assert Floki.find(doc, "[data-testid='paper-week']") == []
        assert Floki.find(doc, "[data-testid='paper-selection']") == []
      end
    end

    test "says so under its heading when no day of the month is free" do
      closed =
        Map.new(Date.range(~D[2030-02-20], ~D[2030-04-10]), &{Date.to_iso8601(&1), false})

      doc = schedule(month_availability_map: closed, availability_status: :loaded)

      assert text(doc, "[data-testid='paper-month-empty']") == "No times available this month"
    end

    test "names the timezone before the calendar and the times" do
      doc = schedule([])

      assert [first | _rest] = Floki.find(doc, ".paper-picker > *")
      assert List.first(Floki.attribute(first, "class")) =~ "paper-timezone"
    end
  end

  describe "the week view" do
    test "says so above the days when the whole week has no free time" do
      empty = Map.new(0..6, &{@monday |> Date.add(&1) |> Date.to_iso8601(), []})
      doc = schedule(theme_tokens: tokens("week"), week_slots: empty)

      assert text(doc, "[data-testid='paper-week-empty']") == "No times available this week"
    end

    test "says nothing of the kind while the week has a free time" do
      doc = schedule(theme_tokens: tokens("week"), week_slots: week_slots())

      assert Floki.find(doc, "[data-testid='paper-week-empty']") == []
    end

    test "renders the week grid with its times, and no month calendar" do
      doc = schedule(theme_tokens: tokens("week"), week_slots: week_slots())

      assert [_section] =
               Floki.find(doc, "section.paper-card.paper-card--week[data-calendar-view='week']")

      assert [_week] = Floki.find(doc, "[data-testid='paper-week'] [data-testid='week-grid']")

      assert text(doc, "[data-testid='paper-week'] .paper-week__title") ==
               "Select a date and time"

      assert [_picker] = Floki.find(doc, "[data-testid='paper-week'] .paper-timezone .tz-picker")

      assert Floki.attribute(doc, "[data-testid='week-slot']", "data-time") ==
               ["10:00 AM", "2:00 PM"]

      assert Floki.attribute(doc, "[data-testid='week-slot']", "data-date") ==
               [@wednesday, @wednesday]

      assert Floki.find(doc, "[data-testid='calendar-day']") == []
      assert Floki.find(doc, ".paper-calendar") == []
    end

    test "asks for its week while none is in, and shows no times" do
      doc = schedule(theme_tokens: tokens("week"), week_slots: nil)

      assert [grid] = Floki.find(doc, "[data-testid='week-grid']")
      assert [binding] = Floki.attribute(grid, "phx-mounted")
      assert binding =~ "load_week"
      assert Floki.find(doc, "[data-testid='week-slot']") == []
    end

    test "keeps the meeting's details and the existing test ids" do
      doc = schedule(theme_tokens: tokens("week"), week_slots: week_slots())

      assert text(doc, "[data-testid='paper-schedule'] .paper-details h1") == "Quick Chat"
      assert [_actions] = Floki.find(doc, "[data-testid='schedule-actions']")

      assert [_back] =
               Floki.find(doc, "[data-testid='schedule-actions'] [data-testid='back-step']")
    end

    test "asks for a time, offers no Next, and shows no details until one is picked" do
      doc =
        schedule(
          theme_tokens: tokens("week"),
          week_slots: week_slots(),
          selected_date: @wednesday
        )

      assert text(doc, "[data-testid='paper-selection']") == "Select a time"
      assert Floki.attribute(doc, "[data-testid='paper-selection']", "aria-live") == ["polite"]
      assert Floki.find(doc, "[data-testid='next-step']") == []
      assert Floki.find(doc, "[data-testid='paper-book']") == []
    end

    test "names the chosen day and time beside Back" do
      doc =
        schedule(
          theme_tokens: tokens("week"),
          week_slots: week_slots(),
          selected_date: @wednesday,
          selected_time: "2:00 PM"
        )

      assert text(doc, "[data-testid='paper-selection'] .paper-selection__date") ==
               "Wednesday, 6 March 2030"

      assert text(doc, "[data-testid='paper-selection'] .paper-selection__time") == "02:00 PM"

      assert Floki.attribute(
               doc,
               "[data-testid='week-slot'].week-grid__slot--selected",
               "data-time"
             ) == ["2:00 PM"]

      ids =
        doc
        |> Floki.find("[data-testid='schedule-actions'] > *")
        |> Enum.flat_map(&Floki.attribute(&1, "data-testid"))

      assert ids == ["back-step", "paper-selection"]
    end
  end
end
