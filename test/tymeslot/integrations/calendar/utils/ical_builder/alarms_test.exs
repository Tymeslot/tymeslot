defmodule Tymeslot.Integrations.Calendar.ICalBuilder.AlarmsTest do
  @moduledoc """
  The VALARMs `build_simple_event/3` writes. RFC 5545 §3.6.6 requires an
  `EMAIL` alarm to carry a `SUMMARY` and an `ATTENDEE`; one written without
  them may be rejected by a strict server or ignored by other clients.
  """
  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :integrations
  @moduletag :unit

  alias Tymeslot.Integrations.Calendar.ICalBuilder
  alias Tymeslot.Integrations.Calendar.ICalBuilder.LineFolder

  @event %{
    summary: "Board meeting, Q3",
    organizer_email: "host@example.com",
    start_time: ~U[2026-09-10 09:00:00Z],
    end_time: ~U[2026-09-10 10:00:00Z]
  }

  defp alarm_lines(event_data) do
    "uid-1"
    |> ICalBuilder.build_simple_event(event_data)
    |> LineFolder.unfold_lines()
    |> Enum.drop_while(&(&1 != "BEGIN:VALARM"))
    |> Enum.take_while(&(&1 != "END:VALARM"))
  end

  describe "an email reminder" do
    test "is addressed to the organiser and titled after the event" do
      lines = alarm_lines(Map.put(@event, :reminders, [%{method: :email, minutes_before: 30}]))

      assert "ACTION:EMAIL" in lines
      assert "ATTENDEE:mailto:host@example.com" in lines
      assert "SUMMARY:Board meeting\\, Q3" in lines
      assert "DESCRIPTION:Reminder" in lines
    end

    test "round-tripped through the cache with string keys is addressed the same way" do
      lines =
        alarm_lines(Map.put(@event, :reminders, [%{"method" => "email", "minutes_before" => 30}]))

      assert "ACTION:EMAIL" in lines
      assert "ATTENDEE:mailto:host@example.com" in lines
      assert "SUMMARY:Board meeting\\, Q3" in lines
    end

    test "on an untitled event still carries a SUMMARY" do
      lines =
        alarm_lines(
          @event
          |> Map.put(:summary, "")
          |> Map.put(:reminders, [%{method: :email, minutes_before: 30}])
        )

      assert "SUMMARY:Reminder" in lines
    end

    test "with no organiser address becomes a display alarm" do
      lines =
        alarm_lines(
          @event
          |> Map.delete(:organizer_email)
          |> Map.put(:reminders, [%{method: :email, minutes_before: 30}])
        )

      assert "ACTION:DISPLAY" in lines
      refute "ACTION:EMAIL" in lines
    end
  end

  test "a popup reminder stays a bare display alarm" do
    lines = alarm_lines(Map.put(@event, :reminders, [%{method: :popup, minutes_before: 10}]))

    assert lines == ["BEGIN:VALARM", "TRIGGER:-PT10M", "ACTION:DISPLAY", "DESCRIPTION:Reminder"]
  end
end
