defmodule Tymeslot.Integrations.Calendar.Google.EventMapperRecurrenceTest do
  use ExUnit.Case, async: true

  @moduletag :integrations
  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.Google.EventMapper

  describe "format_event_data/1 — recurrence" do
    test "emits recurrence as an RRULE-prefixed list" do
      event_data = %{
        summary: "Standup",
        start_time: ~U[2026-04-18 10:00:00Z],
        end_time: ~U[2026-04-18 10:15:00Z],
        recurrence_rule: "FREQ=WEEKLY;BYDAY=MO,WE,FR"
      }

      result = EventMapper.format_event_data(event_data)

      assert result["recurrence"] == ["RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR"]
    end

    test "does not double-prefix a rule that already carries RRULE:" do
      event_data = %{
        summary: "Standup",
        start_time: ~U[2026-04-18 10:00:00Z],
        end_time: ~U[2026-04-18 10:15:00Z],
        recurrence_rule: "RRULE:FREQ=DAILY"
      }

      result = EventMapper.format_event_data(event_data)

      assert result["recurrence"] == ["RRULE:FREQ=DAILY"]
    end

    test "leaves a series' exclusions out of an edit's body" do
      event_data = %{
        summary: "Standup",
        start_time: ~U[2026-04-20 10:00:00Z],
        end_time: ~U[2026-04-20 10:15:00Z],
        recurrence_rule: "FREQ=DAILY;COUNT=5",
        recurrence_exceptions: [~U[2026-04-21 10:00:00Z]]
      }

      assert EventMapper.format_event_data(event_data)["recurrence"] == [
               "RRULE:FREQ=DAILY;COUNT=5"
             ]
    end
  end

  describe "format_new_event_data/1 — recurrence" do
    test "follows a new series' rule with its excluded occurrences" do
      event_data = %{
        summary: "Standup",
        start_time: ~U[2026-04-20 10:00:00Z],
        end_time: ~U[2026-04-20 10:15:00Z],
        recurrence_rule: "FREQ=DAILY;COUNT=5",
        recurrence_exceptions: [~U[2026-04-21 10:00:00Z], ~U[2026-04-23 10:00:00Z]]
      }

      result = EventMapper.format_new_event_data(event_data)

      assert result["recurrence"] == [
               "RRULE:FREQ=DAILY;COUNT=5",
               "EXDATE:20260421T100000Z,20260423T100000Z"
             ]
    end

    test "excludes a new all-day series' occurrences by date" do
      event_data = %{
        summary: "Gym",
        start_time: ~D[2026-04-20],
        end_time: ~D[2026-04-21],
        all_day: true,
        recurrence_rule: "FREQ=WEEKLY",
        recurrence_exceptions: [~D[2026-04-27]]
      }

      result = EventMapper.format_new_event_data(event_data)

      assert result["recurrence"] == ["RRULE:FREQ=WEEKLY", "EXDATE;VALUE=DATE:20260427"]
    end

    test "omits the recurrence key when no rule is present" do
      event_data = %{
        summary: "Once",
        start_time: ~U[2026-04-18 10:00:00Z],
        end_time: ~U[2026-04-18 11:00:00Z]
      }

      result = EventMapper.format_new_event_data(event_data)

      refute Map.has_key?(result, "recurrence")
    end
  end
end
