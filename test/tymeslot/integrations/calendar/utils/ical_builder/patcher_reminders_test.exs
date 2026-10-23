defmodule Tymeslot.Integrations.Calendar.ICalBuilder.PatcherRemindersTest do
  @moduledoc """
  How an edit's reminder list is merged into the stored VALARMs.

  A reminder holds only a method and a lead time, so an alarm rebuilt from
  one loses the rest of what it says. These tests pin that the patcher keeps
  every alarm the list still claims, or cannot express, exactly as stored.
  """
  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :integrations
  @moduletag :unit

  alias Tymeslot.Integrations.Calendar.ICalBuilder
  alias Tymeslot.Integrations.Calendar.ICalBuilder.LineFolder
  alias Tymeslot.Integrations.Calendar.ICalNormaliser

  @event """
  BEGIN:VCALENDAR\r
  VERSION:2.0\r
  BEGIN:VEVENT\r
  UID:reminders-event-1\r
  DTSTAMP:20260901T090000Z\r
  DTSTART:20260910T090000Z\r
  DTEND:20260910T100000Z\r
  SUMMARY:Sprint review\r
  ORGANIZER;CN=Dana:mailto:dana@example.com\r
  BEGIN:VALARM\r
  TRIGGER:-PT10M\r
  ACTION:DISPLAY\r
  DESCRIPTION:Reminder\r
  END:VALARM\r
  END:VEVENT\r
  END:VCALENDAR\r
  """

  defp lines(ical), do: LineFolder.unfold_lines(ical)

  describe "patch_event_properties/3 when the payload states the reminder list" do
    # An AUDIO alarm with a lead time in seconds: the sync reads it,
    # approximately, as a one-minute pop-up.
    @audio_alarm [
      "BEGIN:VALARM",
      "ACTION:AUDIO",
      "TRIGGER:-PT90S",
      "ATTACH;FMTTYPE=audio/basic:https://example.com/chime.au",
      "X-APPLE-DEFAULT-ALARM:TRUE",
      "END:VALARM"
    ]

    @absolute_alarm [
      "BEGIN:VALARM",
      "ACTION:DISPLAY",
      "TRIGGER;VALUE=DATE-TIME:20260909T170000Z",
      "DESCRIPTION:Prepare",
      "END:VALARM"
    ]

    defp with_alarms(alarms) do
      String.replace(
        @event,
        "END:VALARM\r\n",
        "END:VALARM\r\n" <> Enum.map_join(alarms, &(Enum.join(&1, "\r\n") <> "\r\n"))
      )
    end

    defp alarm_blocks(ical) do
      ical
      |> lines()
      |> Enum.chunk_while(
        nil,
        fn
          "BEGIN:VALARM", nil -> {:cont, ["BEGIN:VALARM"]}
          "END:VALARM", block -> {:cont, Enum.reverse(["END:VALARM" | block]), nil}
          line, block when is_list(block) -> {:cont, [line | block]}
          _line, nil -> {:cont, nil}
        end,
        fn _rest -> {:cont, nil} end
      )
    end

    test "an alarm read approximately is kept verbatim while its reading stays in the list" do
      document = with_alarms([@audio_alarm])
      {:ok, reminders} = ICalNormaliser.document_reminders(document)
      assert %{method: :popup, minutes_before: 1} in reminders

      patched =
        ICalBuilder.patch_event_properties(document, %{
          reminders: reminders -- [%{method: :popup, minutes_before: 10}]
        })

      assert alarm_blocks(patched) == [@audio_alarm]
    end

    test "an empty list removes only the alarms a reminder can express" do
      patched =
        ICalBuilder.patch_event_properties(with_alarms([@audio_alarm, @absolute_alarm]), %{
          reminders: []
        })

      assert alarm_blocks(patched) == [@absolute_alarm]
    end

    # The fixture's alarm with an id, so that it cannot be mistaken for one
    # rebuilt from its reminder.
    defp with_alarm_uid do
      String.replace(
        @event,
        "TRIGGER:-PT10M\r\n",
        "TRIGGER:-PT10M\r\nX-WR-ALARMUID:alarm-1\r\n"
      )
    end

    test "each reminder claims one alarm, so a second identical reminder adds one" do
      patched =
        ICalBuilder.patch_event_properties(with_alarm_uid(), %{
          reminders: [
            %{method: :popup, minutes_before: 10},
            %{method: :popup, minutes_before: 10}
          ]
        })

      assert [stored, added] = alarm_blocks(patched)
      assert [stored] == alarm_blocks(with_alarm_uid())
      assert "TRIGGER:-PT10M" in added
      refute "X-WR-ALARMUID:alarm-1" in added
    end

    test "an SMS reminder claims the display alarm it is written as" do
      patched =
        ICalBuilder.patch_event_properties(with_alarm_uid(), %{
          reminders: [%{"method" => "sms", "minutes_before" => 10}]
        })

      assert alarm_blocks(patched) == alarm_blocks(with_alarm_uid())
    end
  end
end
