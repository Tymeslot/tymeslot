defmodule Tymeslot.Integrations.Calendar.Outlook.EventMapperTest do
  use ExUnit.Case, async: true

  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.Attendee
  alias Tymeslot.Integrations.Calendar.Outlook.EventMapper

  describe "format_event_data/1 — all-day events" do
    test "sets isAllDay when start_time is a Date" do
      event_data = %{
        summary: "Holiday",
        start_time: ~D[2026-04-18],
        end_time: ~D[2026-04-19]
      }

      result = EventMapper.format_event_data(event_data)

      assert result["isAllDay"] == true
    end

    test "produces dateTime format for Date start/end (Outlook requires dateTime even for all-day)" do
      event_data = %{
        summary: "Holiday",
        start_time: ~D[2026-04-18],
        end_time: ~D[2026-04-19]
      }

      result = EventMapper.format_event_data(event_data)

      assert result["start"]["dateTime"] == "2026-04-18T00:00:00.0000000"
      assert result["start"]["timeZone"] == "UTC"
      assert result["end"]["dateTime"] == "2026-04-19T00:00:00.0000000"
    end

    test "does not set isAllDay for DateTime start/end" do
      event_data = %{
        summary: "Meeting",
        start_time: ~U[2026-04-18 10:00:00Z],
        end_time: ~U[2026-04-18 11:00:00Z]
      }

      result = EventMapper.format_event_data(event_data)

      refute Map.has_key?(result, "isAllDay")
    end
  end

  describe "format_event_data/1 — showAs (transparency)" do
    test "defaults to busy" do
      event_data = %{
        summary: "Meeting",
        start_time: ~U[2026-04-18 10:00:00Z],
        end_time: ~U[2026-04-18 11:00:00Z]
      }

      result = EventMapper.format_event_data(event_data)

      assert result["showAs"] == "busy"
    end

    test "maps :transparent to free" do
      event_data = %{
        summary: "Out of Office",
        start_time: ~U[2026-04-18 10:00:00Z],
        end_time: ~U[2026-04-18 11:00:00Z],
        transparency: :transparent
      }

      result = EventMapper.format_event_data(event_data)

      assert result["showAs"] == "free"
    end

    test "maps :tentative status to tentative showAs" do
      event_data = %{
        summary: "Maybe Meeting",
        start_time: ~U[2026-04-18 10:00:00Z],
        end_time: ~U[2026-04-18 11:00:00Z],
        status: :tentative
      }

      result = EventMapper.format_event_data(event_data)

      assert result["showAs"] == "tentative"
    end
  end

  describe "format_event_data/1 — sensitivity (visibility)" do
    test "omits sensitivity by default" do
      event_data = %{
        summary: "Meeting",
        start_time: ~U[2026-04-18 10:00:00Z],
        end_time: ~U[2026-04-18 11:00:00Z]
      }

      result = EventMapper.format_event_data(event_data)

      refute Map.has_key?(result, "sensitivity")
    end

    test "maps :private visibility to private sensitivity" do
      event_data = %{
        summary: "Secret Meeting",
        start_time: ~U[2026-04-18 10:00:00Z],
        end_time: ~U[2026-04-18 11:00:00Z],
        visibility: :private
      }

      result = EventMapper.format_event_data(event_data)

      assert result["sensitivity"] == "private"
    end

    test "maps :confidential visibility to confidential sensitivity" do
      event_data = %{
        summary: "Confidential Meeting",
        start_time: ~U[2026-04-18 10:00:00Z],
        end_time: ~U[2026-04-18 11:00:00Z],
        visibility: :confidential
      }

      result = EventMapper.format_event_data(event_data)

      assert result["sensitivity"] == "confidential"
    end
  end

  describe "format_event_data/1 — Content-Type header (regression)" do
    test "timed event produces dateTime without trailing Z when timeZone is present" do
      event_data = %{
        summary: "Meeting",
        start_time: ~U[2026-04-18 10:00:00Z],
        end_time: ~U[2026-04-18 11:00:00Z]
      }

      result = EventMapper.format_event_data(event_data)

      # Event data carrying no timezone still gets one, defaulting to UTC.
      assert result["start"]["timeZone"] == "UTC"

      # Outlook rejects dateTime with Z when timeZone is also present
      refute String.ends_with?(result["start"]["dateTime"], "Z")
    end
  end

  describe "add_tymeslot_fingerprint/1" do
    test "adds singleValueExtendedProperties to the body" do
      body = %{"subject" => "Test"}

      result = EventMapper.add_tymeslot_fingerprint(body)

      assert [%{"value" => "tymeslot"}] = result["singleValueExtendedProperties"]
    end
  end

  # Outlook only supports a single lead-time reminder per event
  # (`reminderMinutesBeforeStart` + `isReminderOn`), so only the first reminder
  # round-trips; method is not representable on Graph.
  describe "format_event_data/1 — reminders" do
    test "maps the first reminder's minutes to reminderMinutesBeforeStart and turns the reminder on" do
      event_data = %{
        summary: "Meeting",
        start_time: ~U[2026-04-18 10:00:00Z],
        end_time: ~U[2026-04-18 11:00:00Z],
        reminders: [
          %{method: :popup, minutes_before: 15},
          %{method: :email, minutes_before: 60}
        ]
      }

      result = EventMapper.format_event_data(event_data)

      assert result["reminderMinutesBeforeStart"] == 15
      assert result["isReminderOn"] == true
    end

    test "sets isReminderOn to false when there are no reminders" do
      event_data = %{
        summary: "Meeting",
        start_time: ~U[2026-04-18 10:00:00Z],
        end_time: ~U[2026-04-18 11:00:00Z]
      }

      result = EventMapper.format_event_data(event_data)

      assert result["isReminderOn"] == false
      refute Map.has_key?(result, "reminderMinutesBeforeStart")
    end

    test "sets isReminderOn to false for an empty reminders list" do
      event_data = %{
        summary: "Meeting",
        start_time: ~U[2026-04-18 10:00:00Z],
        end_time: ~U[2026-04-18 11:00:00Z],
        reminders: []
      }

      result = EventMapper.format_event_data(event_data)

      assert result["isReminderOn"] == false
    end
  end

  describe "format_event_data/1 — recurrence" do
    test "emits a Graph recurrence object for a weekly rule" do
      event_data = %{
        summary: "Standup",
        start_time: ~U[2026-06-15 10:00:00Z],
        end_time: ~U[2026-06-15 10:15:00Z],
        recurrence_rule: "FREQ=WEEKLY;BYDAY=MO,WE"
      }

      result = EventMapper.format_event_data(event_data)

      assert result["recurrence"]["pattern"]["type"] == "weekly"
      assert result["recurrence"]["pattern"]["daysOfWeek"] == ["monday", "wednesday"]
      assert result["recurrence"]["range"]["type"] == "noEnd"
      assert result["recurrence"]["range"]["startDate"] == "2026-06-15"
    end

    test "derives the start date from an all-day Date start" do
      event_data = %{
        summary: "Daily all-day",
        start_time: ~D[2026-06-15],
        end_time: ~D[2026-06-16],
        recurrence_rule: "FREQ=DAILY;COUNT=5"
      }

      result = EventMapper.format_event_data(event_data)

      assert result["recurrence"]["range"]["type"] == "numbered"
      assert result["recurrence"]["range"]["numberOfOccurrences"] == 5
    end

    test "omits recurrence when no rule is present" do
      event_data = %{
        summary: "Once",
        start_time: ~U[2026-06-15 10:00:00Z],
        end_time: ~U[2026-06-15 11:00:00Z]
      }

      result = EventMapper.format_event_data(event_data)

      refute Map.has_key?(result, "recurrence")
    end
  end

  # Graph's PATCH replaces the attendee collection with the one it is sent and
  # ignores `status` on a write, so any attendee array in an update body resets
  # every reply. The array is sent only when the caller supplied a list.
  describe "format_event_data/1 — attendees" do
    defp timed_event(extra) do
      Map.merge(
        %{
          summary: "Sprint review",
          start_time: ~U[2026-06-01 09:00:00Z],
          end_time: ~U[2026-06-01 10:00:00Z],
          timezone: "UTC"
        },
        extra
      )
    end

    test "an edit that says nothing about attendees sends no attendees key" do
      result = EventMapper.format_event_data(timed_event(%{summary: "Renamed"}))

      refute Map.has_key?(result, "attendees")
    end

    test "a supplied list is sent as required attendees" do
      result =
        EventMapper.format_event_data(
          timed_event(%{
            attendees: [
              %{"email" => "ada@example.com", "name" => "Ada"},
              %{email: "bob@example.com"}
            ]
          })
        )

      assert result["attendees"] == [
               %{
                 "emailAddress" => %{"address" => "ada@example.com", "name" => "Ada"},
                 "type" => "required"
               },
               %{
                 "emailAddress" => %{"address" => "bob@example.com", "name" => "bob@example.com"},
                 "type" => "required"
               }
             ]
    end

    # The removal of the last guest, which has to reach Graph as an empty
    # collection rather than as no opinion.
    test "a supplied empty list is sent as an empty collection" do
      result = EventMapper.format_event_data(timed_event(%{attendees: []}))

      assert result["attendees"] == []
    end

    test "a nil attendee list is no opinion and sends no attendees key" do
      result = EventMapper.format_event_data(timed_event(%{attendees: nil}))

      refute Map.has_key?(result, "attendees")
    end

    test "the ad-hoc meeting's single attendee is still sent" do
      result =
        EventMapper.format_event_data(
          timed_event(%{attendee_email: "ada@example.com", attendee_name: "Ada"})
        )

      assert [%{"emailAddress" => %{"address" => "ada@example.com", "name" => "Ada"}}] =
               result["attendees"]
    end

    test "keeps a cached attendee's label rather than replacing it with the address" do
      result =
        EventMapper.format_event_data(
          timed_event(%{
            attendees: [
              %{
                "email" => "ada@example.com",
                "display_name" => "Ada Lovelace",
                "response_status" => "accepted",
                "optional" => false
              }
            ]
          })
        )

      assert [%{"emailAddress" => %{"address" => "ada@example.com", "name" => "Ada Lovelace"}}] =
               result["attendees"]
    end

    test "labels an attendee with no name by their address" do
      result =
        EventMapper.format_event_data(
          timed_event(%{attendees: [Attendee.new(email: "ada@example.com")]})
        )

      assert [%{"emailAddress" => %{"address" => "ada@example.com", "name" => "ada@example.com"}}] =
               result["attendees"]
    end

    test "drops an attendee with no address" do
      result =
        EventMapper.format_event_data(
          timed_event(%{
            attendees: [Attendee.new(email: "ada@example.com"), %{"display_name" => "Nobody"}]
          })
        )

      assert [%{"emailAddress" => %{"address" => "ada@example.com"}}] = result["attendees"]
    end
  end
end
