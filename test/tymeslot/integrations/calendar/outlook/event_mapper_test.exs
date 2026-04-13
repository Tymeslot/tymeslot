defmodule Tymeslot.Integrations.Calendar.Outlook.EventMapperTest do
  use ExUnit.Case, async: true

  @moduletag :integrations

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

      # Outlook rejects dateTime with Z when timeZone is also present
      if result["start"]["timeZone"] do
        refute String.ends_with?(result["start"]["dateTime"], "Z")
      end
    end
  end

  describe "add_tymeslot_fingerprint/1" do
    test "adds singleValueExtendedProperties to the body" do
      body = %{"subject" => "Test"}

      result = EventMapper.add_tymeslot_fingerprint(body)

      assert [%{"value" => "tymeslot"}] = result["singleValueExtendedProperties"]
    end
  end
end
