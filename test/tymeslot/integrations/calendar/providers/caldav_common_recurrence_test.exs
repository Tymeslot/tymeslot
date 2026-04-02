defmodule Tymeslot.Integrations.Calendar.Providers.CaldavCommonRecurrenceTest do
  use ExUnit.Case, async: true

  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.Providers.CaldavCommon

  describe "expand_recurring_events/3" do
    test "expands recurring events and preserves non-recurring ones" do
      events = [
        %{
          uid: "single-1",
          summary: "One-off",
          start_time: ~U[2026-04-10 10:00:00Z],
          end_time: ~U[2026-04-10 11:00:00Z],
          recurrence_rule: nil,
          exdates: []
        },
        %{
          uid: "weekly-1",
          summary: "Weekly",
          start_time: ~U[2026-04-03 09:00:00Z],
          end_time: ~U[2026-04-03 10:00:00Z],
          recurrence_rule: "FREQ=WEEKLY;INTERVAL=1",
          exdates: []
        }
      ]

      range_start = ~U[2026-04-10 00:00:00Z]
      range_end = ~U[2026-04-10 23:59:59Z]

      expanded = CaldavCommon.expand_recurring_events(events, range_start, range_end)

      summaries = Enum.map(expanded, & &1.summary)
      assert "One-off" in summaries
      assert "Weekly" in summaries

      weekly = Enum.find(expanded, &(&1.summary == "Weekly"))
      assert weekly.start_time == ~U[2026-04-10 09:00:00Z]
    end

    test "passes exdates to expander" do
      events = [
        %{
          uid: "ex-1",
          summary: "Skipped",
          start_time: ~U[2026-04-03 09:00:00Z],
          end_time: ~U[2026-04-03 10:00:00Z],
          recurrence_rule: "FREQ=WEEKLY;INTERVAL=1",
          exdates: [~U[2026-04-10 09:00:00Z]]
        }
      ]

      range_start = ~U[2026-04-10 00:00:00Z]
      range_end = ~U[2026-04-10 23:59:59Z]

      expanded = CaldavCommon.expand_recurring_events(events, range_start, range_end)
      assert expanded == []
    end

    test "handles events without exdates key" do
      events = [
        %{
          uid: "no-exdates",
          summary: "Legacy",
          start_time: ~U[2026-04-03 09:00:00Z],
          end_time: ~U[2026-04-03 10:00:00Z],
          recurrence_rule: "FREQ=WEEKLY;INTERVAL=1"
        }
      ]

      range_start = ~U[2026-04-10 00:00:00Z]
      range_end = ~U[2026-04-10 23:59:59Z]

      expanded = CaldavCommon.expand_recurring_events(events, range_start, range_end)
      assert [%{start_time: ~U[2026-04-10 09:00:00Z]}] = expanded
    end
  end
end
