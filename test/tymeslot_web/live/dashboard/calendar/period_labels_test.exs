defmodule TymeslotWeb.Dashboard.Calendar.PeriodLabelsTest do
  @moduledoc """
  The words for a calendar period: the toolbar's title, the phone header's
  shorter one, what previous and next step by, and each view's name.
  """

  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :unit

  alias Tymeslot.CalendarGrid.Period
  alias TymeslotWeb.Dashboard.Calendar.PeriodLabels

  defp title(view, date), do: label(&PeriodLabels.title/4, view, date)
  defp short(view, date), do: label(&PeriodLabels.short_title/4, view, date)
  defp compact(view, date), do: label(&PeriodLabels.compact_title/4, view, date)

  defp label(fun, view, date), do: fun.(view, date, Period.days(view, date, :monday, true), "en")

  describe "title/4" do
    test "a day is its full date" do
      assert title(:day, ~D[2026-10-20]) == "Tuesday, 20 October 2026"
    end

    test "days inside one month are that month" do
      assert title(:week, ~D[2026-10-14]) == "October 2026"
    end

    test "days across two months name both, across two years both years" do
      assert title(:three_day, ~D[2026-10-30]) == "Oct – November 2026"
      assert title(:three_day, ~D[2026-12-31]) == "December 2026 – January 2027"
    end

    test "a month is its own month, though its grid starts in the month before" do
      assert title(:month, ~D[2026-10-14]) == "October 2026"
      assert title(:month, ~D[2026-11-01]) == "November 2026"
    end

    test "an agenda says where it starts" do
      assert title(:agenda, ~D[2026-10-19]) == "From Mon 19 Oct"
    end
  end

  describe "short_title/4" do
    test "fits the phone header" do
      assert short(:day, ~D[2026-10-19]) == "Mon 19 Oct"
      assert short(:three_day, ~D[2026-10-19]) == "19 to 21 Oct"
      assert short(:week, ~D[2026-10-14]) == "12 to 18 Oct"
      assert short(:month, ~D[2026-10-14]) == "Oct 2026"
      assert short(:agenda, ~D[2026-10-19]) == "From 19 Oct"
    end

    test "names both months when the days cross into the next" do
      assert short(:three_day, ~D[2026-10-30]) == "30 Oct to 1 Nov"
    end
  end

  describe "compact_title/4" do
    test "gives a range a dash in place of its words and keeps the other titles short" do
      assert compact(:three_day, ~D[2026-10-19]) == "19 – 21 Oct"
      assert compact(:week, ~D[2026-10-14]) == "12 – 18 Oct"
      assert compact(:three_day, ~D[2026-10-30]) == "30 Oct – 1 Nov"
      assert compact(:day, ~D[2026-10-19]) == "Mon 19 Oct"
      assert compact(:month, ~D[2026-10-14]) == "Oct 2026"
      assert compact(:agenda, ~D[2026-10-19]) == "From 19 Oct"
    end
  end

  # Italian says "from" with the article merged into "da", elided before a day
  # read with a vowel, and the article opens the title.
  describe "an agenda's start in Italian" do
    setup do
      Gettext.put_locale(TymeslotWeb.Gettext, "it")
      :ok
    end

    defp italian(fun, date),
      do: fun.(:agenda, date, Period.days(:agenda, date, :monday, true), "it")

    test "elides the article before the 8th and capitalises it" do
      assert italian(&PeriodLabels.short_title/4, ~D[2026-10-08]) == "Dall'8 ott"
      assert italian(&PeriodLabels.short_title/4, ~D[2026-10-09]) == "Dal 9 ott"
    end

    test "puts the article before the weekday when the weekday leads" do
      assert italian(&PeriodLabels.title/4, ~D[2026-10-08]) == "Dal gio 8 ott"
    end
  end

  test "step_label/2 names what previous and next step by, for every view" do
    labels =
      for view <- Period.views(),
          do: {PeriodLabels.step_label(view, :previous), PeriodLabels.step_label(view, :next)}

    assert labels == [
             {"Previous day", "Next day"},
             {"Previous three days", "Next three days"},
             {"Previous week", "Next week"},
             {"Previous month", "Next month"},
             {"Earlier", "Later"}
           ]
  end

  test "view_label/1 names every view" do
    assert Enum.map(Period.views(), &PeriodLabels.view_label/1) ==
             ["Day", "3 days", "Week", "Month", "Agenda"]
  end
end
