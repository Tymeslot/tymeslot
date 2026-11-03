defmodule TymeslotWeb.OnboardingLive.PreviewPartsTest do
  use ExUnit.Case, async: true

  @moduletag :onboarding
  @moduletag :components

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias Tymeslot.Availability.WeekPreview
  alias Tymeslot.ThemeCustomizations.Tokens
  alias TymeslotWeb.OnboardingLive.PreviewParts
  alias TymeslotWeb.OnboardingLive.PreviewWeek
  alias TymeslotWeb.Themes.Core.ThemeInfo
  alias TymeslotWeb.ThemeTestMatrix

  defmodule Bare do
    @moduledoc false
    # A theme module that draws no onboarding preview of its own.
  end

  # Tuesday 3 November 2026.
  @today ~D[2026-11-03]

  # A week from Tuesday whose Tuesday has two times and a busy hour, whose
  # Wednesday is fully booked, and whose other days are open at 10:30.
  defp ready_week do
    days =
      for offset <- 0..6 do
        date = Date.add(@today, offset)

        case offset do
          0 -> %{date: date, slots: ["09:00", "09:30"], busy: [{~T[14:00:00], ~T[15:00:00]}]}
          1 -> %{date: date, slots: [], busy: [{~T[09:00:00], ~T[17:00:00]}]}
          _other -> %{date: date, slots: ["10:30"], busy: []}
        end
      end

    %{
      state: :ready,
      preview: %WeekPreview{
        days: days,
        slot_count: 7,
        first_busy: %{date: @today, start: ~T[14:00:00]}
      }
    }
  end

  defp card(module, week, highlight \\ []) do
    assigns = %{module: module, week: week, today: @today, highlight: highlight}

    rendered_to_string(~H"""
    <PreviewParts.theme_preview
      theme_module={@module}
      variant={:card}
      colors={%{}}
      week={@week}
      today={@today}
      highlight={@highlight}
    >
      <:header>
        <p id="shared-header">Ada Lovelace</p>
      </:header>
    </PreviewParts.theme_preview>
    """)
  end

  defp doc(html), do: Floki.parse_fragment!(html)

  # A ready week of seven days with no free time at all.
  defp empty_week do
    days = for offset <- 0..6, do: %{date: Date.add(@today, offset), slots: [], busy: []}
    %{state: :ready, preview: %WeekPreview{days: days, slot_count: 0, first_busy: nil}}
  end

  defp times_text(html),
    do: html |> doc() |> Floki.find("[data-preview-part='times']") |> Floki.text()

  # Every shipped theme, and the generic mock a theme without a preview of
  # its own gets: one contract.
  @modules Enum.map(ThemeTestMatrix.ids(), &{"theme #{&1}", ThemeInfo.get_theme_module(&1)}) ++
             [{"the generic mock", Bare}]

  describe "theme_preview/1" do
    for theme_id <- ThemeTestMatrix.ids() do
      test "theme #{theme_id} draws a thumbnail tinted with the primary colour" do
        html =
          render_component(&PreviewParts.theme_preview/1,
            theme_module: ThemeInfo.get_theme_module(unquote(theme_id)),
            variant: :thumbnail,
            primary: "#123456"
          )

        assert html =~ "#123456"
      end
    end
  end

  describe "the week on the card" do
    for {name, module} <- @modules do
      @module module

      test "#{name} renders real slot labels in the ready state" do
        html = card(@module, ready_week())

        assert html =~ ~s(id="shared-header")
        assert html =~ "Book"
        # The chosen day is the first with times: Tuesday's two, and no
        # other day's.
        assert times_text(html) =~ "09:00"
        assert times_text(html) =~ "09:30"
        refute html =~ "10:30"
        assert html =~ "data-reveal-item"
      end

      test "#{name} renders the placeholder line before a calendar" do
        html = card(@module, %{state: :placeholder, preview: nil})

        assert html =~ "Your free times appear here once your calendar is connected."
        refute html =~ "data-reveal-item"
        # No day is offered before the calendar is read.
        states =
          html
          |> doc()
          |> Floki.find("[data-day-state]")
          |> Enum.flat_map(&Floki.attribute(&1, "data-day-state"))

        refute "open" in states
        refute "selected" in states
      end

      test "#{name} says the calendar is being read while it loads" do
        html = card(@module, %{state: :loading, preview: nil})

        assert html =~ "Reading your calendar…"
        assert html =~ "onboarding-preview-shimmer"
      end

      test "#{name} keeps its times the same size in every state" do
        counts =
          for week <- [
                ready_week(),
                %{state: :placeholder, preview: nil},
                %{state: :loading, preview: nil},
                %{state: :slow, preview: nil},
                %{state: :failed, preview: nil}
              ] do
            @module
            |> card(week)
            |> doc()
            |> Floki.find("[data-preview-part='times'] > div > span")
            |> length()
          end

        assert [count | _rest] = counts
        assert count > 0
        assert Enum.uniq(counts) == [count]
      end

      test "#{name} rings and focuses the region its step highlights" do
        for {region, highlight} <- [{"calendar", [:calendar]}, {"slots", [:slots]}] do
          ringed =
            @module
            |> card(ready_week(), highlight)
            |> doc()
            |> Floki.find("[data-stage-focus]")

          assert [element] = ringed
          assert Floki.attribute(element, "data-preview-region") == [region]
          assert [style] = Floki.attribute(element, "style")
          assert style =~ "outline: 2px solid"
        end

        html = card(@module, ready_week(), [])
        assert Floki.find(doc(html), "[data-stage-focus]") == []
        refute html =~ "outline:"
      end

      test "#{name} says so when the week has no free time" do
        html = card(@module, empty_week())

        assert [message] = html |> doc() |> Floki.find("[data-role='week-message']")
        assert Floki.text(message) =~ "No free times in the next seven days."
        assert html |> doc() |> Floki.find("[data-entry]") == []
      end

      test "#{name} sends a slow or failed week to the page" do
        for state <- [:slow, :failed] do
          html = card(@module, %{state: state, preview: nil})

          assert html =~ "Connected. Your free times will appear on your page."
          refute html =~ "Your free times appear here"
        end
      end
    end

    test "a theme with a day view hatches the busy hour between the times" do
      for module <- [TymeslotWeb.Themes.Rhythm.Theme, TymeslotWeb.Themes.Paper.Theme, Bare] do
        entries =
          module
          |> card(ready_week())
          |> doc()
          |> Floki.find("[data-preview-part='times'] [data-entry]")
          |> Enum.map(&{Floki.attribute(&1, "data-entry"), String.trim(Floki.text(&1))})

        assert entries == [
                 {["slot"], "09:00 AM"},
                 {["slot"], "09:30 AM"},
                 {["busy"], "02:00 PM – 03:00 PM"}
               ]

        assert [busy] =
                 module
                 |> card(ready_week())
                 |> doc()
                 |> Floki.find("[data-entry='busy']")

        assert [class] = Floki.attribute(busy, "class")
        assert class =~ "onboarding-preview-busy"
      end
    end

    test "a month-grid theme numbers the real days and marks a day with no times unavailable" do
      for module <- [TymeslotWeb.Themes.Quill.Theme, TymeslotWeb.Themes.Folio.Theme] do
        cells =
          module
          |> card(ready_week())
          |> doc()
          |> Floki.find("[data-preview-part='month'] [data-day-state]")
          |> Enum.map(&{String.trim(Floki.text(&1)), hd(Floki.attribute(&1, "data-day-state"))})

        # Monday 2 November to Sunday 15 November.
        assert length(cells) == 14
        assert Enum.at(cells, 0) == {"2", "outside"}
        assert Enum.at(cells, 1) == {"3", "selected"}
        assert Enum.at(cells, 2) == {"4", "closed"}
        assert Enum.at(cells, 3) == {"5", "open"}
        assert Enum.at(cells, 8) == {"10", "outside"}

        # Only a day of the seven without times reads as unavailable; the
        # days after the week shown are plain numbers.
        outside =
          module
          |> card(ready_week())
          |> doc()
          |> Floki.find("[data-preview-part='month'] [data-day-state='outside']")

        assert outside != []

        for cell <- outside do
          assert [class] = Floki.attribute(cell, "class")
          refute class =~ "line-through"
          assert [style] = Floki.attribute(cell, "style")
          refute style =~ "opacity"
        end
      end
    end

    test "the week strip shows the coming seven days from today" do
      html = card(TymeslotWeb.Themes.Rhythm.Theme, %{state: :placeholder, preview: nil})

      days =
        html
        |> doc()
        |> Floki.find("[data-preview-part='days'] [data-day-state]")
        |> Enum.map(&Floki.text/1)

      assert Enum.map(days, &String.replace(&1, ~r/\s+/, "")) ==
               ~w(Tue3 Wed4 Thu5 Fri6 Sat7 Sun8 Mon9)
    end

    test "before a calendar the month grid numbers the coming week's real days" do
      cells =
        TymeslotWeb.Themes.Quill.Theme
        |> card(%{state: :placeholder, preview: nil})
        |> doc()
        |> Floki.find("[data-preview-part='month'] [data-day-state]")
        |> Enum.map(&{String.trim(Floki.text(&1)), hd(Floki.attribute(&1, "data-day-state"))})

      assert Enum.take(cells, 3) == [{"2", "outside"}, {"3", "idle"}, {"4", "idle"}]
    end

    test "Paper's day note counts no free times in an empty week" do
      html = card(TymeslotWeb.Themes.Paper.Theme, empty_week())

      assert [day] = html |> doc() |> Floki.find("[data-preview-part='day']")
      assert Floki.text(day) =~ "0 free times"
    end

    test "a ready month grid is anchored on the week's own dates, not today" do
      # A week read on Friday 30 October, still open on Tuesday 3 November.
      days =
        for offset <- 0..6 do
          date = Date.add(~D[2026-10-30], offset)
          %{date: date, slots: if(offset == 0, do: ["09:00"], else: []), busy: []}
        end

      week = %{state: :ready, preview: %WeekPreview{days: days, slot_count: 1, first_busy: nil}}

      month =
        TymeslotWeb.Themes.Quill.Theme
        |> card(week)
        |> doc()
        |> Floki.find("[data-preview-part='month']")

      assert Floki.text(month) =~ "October 2026"

      cells =
        month
        |> Floki.find("[data-day-state]")
        |> Enum.map(&{String.trim(Floki.text(&1)), hd(Floki.attribute(&1, "data-day-state"))})

      # Monday 26 October onwards: the chosen Friday is on the grid.
      assert Enum.at(cells, 0) == {"26", "outside"}
      assert Enum.at(cells, 4) == {"30", "selected"}
    end

    test "before a calendar Paper opens on today's real date" do
      html = card(TymeslotWeb.Themes.Paper.Theme, %{state: :placeholder, preview: nil})

      assert [day] = html |> doc() |> Floki.find("[data-preview-part='day']")
      assert Floki.text(day) =~ "Tuesday, 3 November"
    end
  end

  describe "each theme keeps its own shape" do
    test "Quill's card has the month calendar and Rhythm's does not" do
      quill = card(TymeslotWeb.Themes.Quill.Theme, ready_week())
      rhythm = card(TymeslotWeb.Themes.Rhythm.Theme, ready_week())

      assert quill =~ ~s(data-preview-part="month")
      refute rhythm =~ ~s(data-preview-part="month")
    end
  end

  describe "agenda_window/2" do
    defp entry(kind, at), do: %{kind: kind, label: at, at: Time.from_iso8601!(at <> ":00")}

    test "shifts the window so a busy block past the limit stays in view" do
      agenda =
        Enum.map(~w(09:00 09:30 10:00 10:30 11:00 11:30), &entry(:slot, &1)) ++
          [entry(:busy, "14:00"), entry(:slot, "15:00")]

      window = PreviewWeek.agenda_window(agenda, 5)

      # The busy block, and the time after it, close the window.
      assert Enum.map(window, & &1.label) == ~w(10:30 11:00 11:30 14:00 15:00)
      assert Enum.at(window, 3).kind == :busy
    end

    test "keeps the first entries when the busy block is already in view" do
      agenda = [entry(:slot, "09:00"), entry(:busy, "10:00"), entry(:slot, "11:00")]

      assert PreviewWeek.agenda_window(agenda, 2) == Enum.take(agenda, 2)
    end
  end

  describe "colors/1" do
    test "reads the previews' colours from resolved tokens, leaving out what the theme lacks" do
      tokens = %Tokens{
        vars: %{
          "--theme-primary" => "#111111",
          "--theme-canvas" => "#222222",
          "--theme-background" => "var(--theme-canvas)"
        }
      }

      assert PreviewParts.colors(tokens) == %{primary: "#111111", background: "#222222"}
    end
  end
end
