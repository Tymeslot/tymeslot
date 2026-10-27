defmodule Tymeslot.Integrations.Calendar.Recurrence.PatternComparisonBoundTest do
  @moduledoc """
  How much work comparing two repeat rules costs. The grid's repeat editor
  compares the rule being built with the stored one on every change, over a
  horizon of up to sixty years when either rule is yearly, so a frequent
  rule must not be expanded over all of it. The expander warns whenever it
  cuts a series short, which is what these tests observe instead of time.
  """

  # Absence of a log event is asserted, and the capture handler is global.
  use ExUnit.Case, async: false

  @moduletag :calendar
  @moduletag :unit

  alias Tymeslot.Integrations.Calendar.Recurrence.Pattern
  alias Tymeslot.Test.LogCapture

  @start DateTime.new!(~D[2026-10-20], ~T[09:00:00], "Europe/Berlin")

  @every_day_yearly "FREQ=YEARLY;BYDAY=MO,TU,WE,TH,FR,SA,SU"

  defp cut_short?(event),
    do: LogCapture.dump(event) =~ "Recurrence expansion stopped after"

  setup do
    LogCapture.attach(level: :warning)
  end

  test "a daily rule is told apart from a yearly one without expanding it for sixty years" do
    refute Pattern.equivalent?("FREQ=DAILY", "FREQ=YEARLY", @start)
    refute Pattern.equivalent?("FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR", "FREQ=YEARLY", @start)

    assert Enum.filter(LogCapture.drain(), &cut_short?/1) == []
  end

  test "a stored rule is read without expanding it over every candidate's horizon" do
    assert Pattern.read(@every_day_yearly, @start) == :custom
    assert Enum.filter(LogCapture.drain(), &cut_short?/1) == []
  end

  test "two rules that agree every day are compared over a bounded number of occurrences" do
    assert Pattern.equivalent?("FREQ=DAILY", @every_day_yearly, @start)

    LogCapture.await_log("Recurrence expansion stopped after #{6 * 366 + 2} occurrences")
  end
end
