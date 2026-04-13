defmodule Tymeslot.Integrations.Calendar.Google.EventMapperTest do
  use ExUnit.Case, async: true

  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.Google.EventMapper

  describe "uuid_to_google_event_id/1 — base32hex fast path" do
    test "strips hyphens from a standard UUID and returns lowercased base32hex" do
      # Standard UUID: all hex digits a-f and 0-9 → valid base32hex after hyphen removal
      uuid = "550e8400-e29b-41d4-a716-446655440000"
      result = EventMapper.uuid_to_google_event_id(uuid)

      assert result == "550e8400e29b41d4a716446655440000"
    end

    test "strips @google.com domain suffix from a Google iCalUID" do
      ical_uid = "abc123def456abc1@google.com"
      result = EventMapper.uuid_to_google_event_id(ical_uid)

      assert result == "abc123def456abc1"
    end

    test "lowercases an uppercase base32hex string" do
      uid = "AABBCCDD11223344"
      result = EventMapper.uuid_to_google_event_id(uid)

      assert result == "aabbccdd11223344"
    end

    test "accepts a string that is already valid lowercase base32hex" do
      uid = "aabbccdd00112233"
      assert EventMapper.uuid_to_google_event_id(uid) == uid
    end
  end

  describe "uuid_to_google_event_id/1 — SHA-256 fallback path" do
    test "hashes a UID containing characters outside base32hex (e.g. g-z)" do
      # 'g' is outside a-v0-9, so this must fall back to SHA-256 + Base.encode32
      uid = "meeting-slug-with-words"
      result = EventMapper.uuid_to_google_event_id(uid)

      # Base.encode32 uses lowercase a-z and 2-7; result is truncated to 32 chars
      assert String.length(result) == 32
      assert String.match?(result, ~r/^[a-z2-7]+$/)
    end

    test "is deterministic — same UID always produces the same Google event ID" do
      uid = "some-arbitrary-string-with-specials!"
      assert EventMapper.uuid_to_google_event_id(uid) == EventMapper.uuid_to_google_event_id(uid)
    end

    test "produces different IDs for different UIDs" do
      id1 = EventMapper.uuid_to_google_event_id("uid-one")
      id2 = EventMapper.uuid_to_google_event_id("uid-two")

      refute id1 == id2
    end

    test "hashes a UID that is fewer than 5 characters after stripping" do
      # Strips @ suffix → "ab", which is only 2 chars → below 5-char minimum → fallback
      uid = "ab@somehost.com"
      result = EventMapper.uuid_to_google_event_id(uid)

      # Must be a valid 32-char hash of the FULL uid (not just "ab")
      assert String.length(result) == 32
      assert String.match?(result, ~r/^[a-z2-7]+$/)
    end

    test "hashes the full UID (not just the local part) to avoid collisions" do
      # Two UIDs with the same local-part but different domains must produce different IDs
      id1 = EventMapper.uuid_to_google_event_id("abc@domain1.com")
      id2 = EventMapper.uuid_to_google_event_id("abc@domain2.com")

      refute id1 == id2
    end
  end

  describe "format_event_data/1" do
    test "builds a Google Calendar event body from atom-keyed event data" do
      event_data = %{
        summary: "Sprint Planning",
        description: "Plan the next sprint",
        location: "https://meet.example.com",
        start_time: ~U[2026-06-01 09:00:00Z],
        end_time: ~U[2026-06-01 10:00:00Z],
        timezone: "UTC",
        status: "confirmed"
      }

      result = EventMapper.format_event_data(event_data)

      assert result["summary"] == "Sprint Planning"
      assert result["description"] == "Plan the next sprint"
      assert result["location"] == "https://meet.example.com"
      assert result["status"] == "confirmed"
    end

    test "accepts string-keyed event data (legacy path)" do
      event_data = %{
        "summary" => "Retro",
        "start_time" => ~U[2026-06-02 14:00:00Z],
        "end_time" => ~U[2026-06-02 15:00:00Z],
        "timezone" => "UTC"
      }

      result = EventMapper.format_event_data(event_data)

      assert result["summary"] == "Retro"
    end

    test "includes a Google event ID derived from uid when uid is present" do
      event_data = %{
        uid: "550e8400-e29b-41d4-a716-446655440000",
        summary: "Meeting",
        start_time: ~U[2026-06-01 09:00:00Z],
        end_time: ~U[2026-06-01 10:00:00Z],
        timezone: "UTC"
      }

      result = EventMapper.format_event_data(event_data)

      assert result["id"] == "550e8400e29b41d4a716446655440000"
    end

    test "omits the id field when uid is absent" do
      event_data = %{
        summary: "No UID Meeting",
        start_time: ~U[2026-06-01 09:00:00Z],
        end_time: ~U[2026-06-01 10:00:00Z],
        timezone: "UTC"
      }

      result = EventMapper.format_event_data(event_data)

      refute Map.has_key?(result, "id")
    end

    test "strips nil values from the result" do
      event_data = %{
        summary: "Minimal Meeting",
        description: nil,
        location: nil,
        start_time: ~U[2026-06-01 09:00:00Z],
        end_time: ~U[2026-06-01 10:00:00Z],
        timezone: "UTC"
      }

      result = EventMapper.format_event_data(event_data)

      refute Map.has_key?(result, "description")
      refute Map.has_key?(result, "location")
    end

    test "builds attendees list from multi-attendee data" do
      event_data = %{
        summary: "Group Meeting",
        start_time: ~U[2026-06-01 09:00:00Z],
        end_time: ~U[2026-06-01 10:00:00Z],
        timezone: "UTC",
        attendees: [
          %{"email" => "alice@example.com", "name" => "Alice"},
          %{"email" => "bob@example.com", "name" => "Bob"}
        ]
      }

      result = EventMapper.format_event_data(event_data)

      attendees = result["attendees"]
      assert length(attendees) == 2
      assert Enum.any?(attendees, &(&1["email"] == "alice@example.com"))
      assert Enum.any?(attendees, &(&1["email"] == "bob@example.com"))
    end

    test "builds single-attendee list from legacy attendee_email/attendee_name fields" do
      event_data = %{
        summary: "1-on-1",
        start_time: ~U[2026-06-01 09:00:00Z],
        end_time: ~U[2026-06-01 10:00:00Z],
        timezone: "UTC",
        attendee_email: "charlie@example.com",
        attendee_name: "Charlie"
      }

      result = EventMapper.format_event_data(event_data)

      [attendee] = result["attendees"]
      assert attendee["email"] == "charlie@example.com"
      assert attendee["displayName"] == "Charlie"
    end
  end

  describe "format_event_data/1 — transparency" do
    test "includes transparency when provided as atom" do
      event_data = %{
        summary: "Free Block",
        start_time: ~U[2026-06-01 09:00:00Z],
        end_time: ~U[2026-06-01 10:00:00Z],
        timezone: "UTC",
        transparency: :transparent
      }

      result = EventMapper.format_event_data(event_data)

      assert result["transparency"] == "transparent"
    end

    test "omits transparency when not provided" do
      event_data = %{
        summary: "Meeting",
        start_time: ~U[2026-06-01 09:00:00Z],
        end_time: ~U[2026-06-01 10:00:00Z],
        timezone: "UTC"
      }

      result = EventMapper.format_event_data(event_data)

      refute Map.has_key?(result, "transparency")
    end
  end

  describe "format_event_data/1 — visibility" do
    test "includes visibility when provided as atom" do
      event_data = %{
        summary: "Private Meeting",
        start_time: ~U[2026-06-01 09:00:00Z],
        end_time: ~U[2026-06-01 10:00:00Z],
        timezone: "UTC",
        visibility: :private
      }

      result = EventMapper.format_event_data(event_data)

      assert result["visibility"] == "private"
    end

    test "omits visibility when not provided" do
      event_data = %{
        summary: "Normal Meeting",
        start_time: ~U[2026-06-01 09:00:00Z],
        end_time: ~U[2026-06-01 10:00:00Z],
        timezone: "UTC"
      }

      result = EventMapper.format_event_data(event_data)

      refute Map.has_key?(result, "visibility")
    end
  end

  describe "format_event_data/1 — status" do
    test "accepts atom status and converts to string" do
      event_data = %{
        summary: "Tentative",
        start_time: ~U[2026-06-01 09:00:00Z],
        end_time: ~U[2026-06-01 10:00:00Z],
        timezone: "UTC",
        status: :tentative
      }

      result = EventMapper.format_event_data(event_data)

      assert result["status"] == "tentative"
    end

    test "defaults to confirmed when status is nil" do
      event_data = %{
        summary: "Meeting",
        start_time: ~U[2026-06-01 09:00:00Z],
        end_time: ~U[2026-06-01 10:00:00Z],
        timezone: "UTC"
      }

      result = EventMapper.format_event_data(event_data)

      assert result["status"] == "confirmed"
    end
  end

  describe "format_event_data/1 — all-day events" do
    test "produces date-only format for Date start/end" do
      event_data = %{
        summary: "Holiday",
        start_time: ~D[2026-06-01],
        end_time: ~D[2026-06-02],
        timezone: nil
      }

      result = EventMapper.format_event_data(event_data)

      assert result["start"] == %{"date" => "2026-06-01"}
      assert result["end"] == %{"date" => "2026-06-02"}
    end
  end

  describe "add_tymeslot_fingerprint/1" do
    test "adds source and extendedProperties to an existing event body" do
      body = %{"summary" => "My Event"}

      result = EventMapper.add_tymeslot_fingerprint(body)

      assert result["source"] == %{"title" => "Tymeslot", "url" => "https://tymeslot.app"}
      assert result["extendedProperties"] == %{"private" => %{"createdBy" => "tymeslot"}}
    end

    test "preserves existing keys in the body" do
      body = %{"summary" => "My Event", "status" => "confirmed"}

      result = EventMapper.add_tymeslot_fingerprint(body)

      assert result["summary"] == "My Event"
      assert result["status"] == "confirmed"
    end
  end
end
