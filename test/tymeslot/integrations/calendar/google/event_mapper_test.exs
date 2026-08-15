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
      # 'g' is outside a-v0-9, so this must fall back to a hash.
      uid = "meeting-slug-with-words"
      result = EventMapper.uuid_to_google_event_id(uid)

      assert String.length(result) == 32
      assert String.match?(result, ~r/^[a-v0-9]+$/)
    end

    # The fallback exists to guarantee a valid id for input that is not already
    # one, so producing an invalid id is the one thing it must never do.
    #
    # It did. `Base.encode32/2` is *standard* base32 — a-z and 2-7 — while
    # Google requires base32hex, a-v and 0-9. Every hash containing w, x, y or
    # z was rejected with "Invalid resource id value", and at 32 characters
    # almost all of them contain one. Mirror UIDs are hashed twice, so they
    # always took this path: cross-calendar sync onto a Google target failed
    # 98.7% of the time, and the assertion that should have caught it asserted
    # the wrong alphabet.
    test "never emits a character Google rejects, over a large sample" do
      offending =
        1..2000
        |> Enum.map(&EventMapper.uuid_to_google_event_id("tymeslot-mirror-sample-#{&1}"))
        |> Enum.reject(&String.match?(&1, ~r/^[a-v0-9]{5,1024}$/))

      assert offending == [],
             "#{length(offending)}/2000 ids used characters outside base32hex, e.g. #{inspect(Enum.take(offending, 3))}"
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
      assert String.match?(result, ~r/^[a-v0-9]+$/)
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

  describe "format_event_data/1 — colour" do
    test "maps a palette colour key to a Google colorId" do
      event_data = %{
        summary: "Coloured",
        start_time: ~U[2026-06-01 09:00:00Z],
        end_time: ~U[2026-06-01 10:00:00Z],
        timezone: "UTC",
        colour: "tomato"
      }

      result = EventMapper.format_event_data(event_data)

      assert result["colorId"] == "11"
    end

    test "omits colorId when no colour override is set" do
      event_data = %{
        summary: "Default",
        start_time: ~U[2026-06-01 09:00:00Z],
        end_time: ~U[2026-06-01 10:00:00Z],
        timezone: "UTC"
      }

      result = EventMapper.format_event_data(event_data)

      refute Map.has_key?(result, "colorId")
    end

    test "omits colorId for an unrecognised colour value" do
      event_data = %{
        summary: "Raw",
        start_time: ~U[2026-06-01 09:00:00Z],
        end_time: ~U[2026-06-01 10:00:00Z],
        timezone: "UTC",
        colour: "11"
      }

      result = EventMapper.format_event_data(event_data)

      refute Map.has_key?(result, "colorId")
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

  describe "format_event_data/1 — conference_data" do
    test "includes conferenceData (stringified) when :conference_data is set" do
      event_data = %{
        summary: "Team Sync",
        start_time: ~U[2026-06-01 09:00:00Z],
        end_time: ~U[2026-06-01 10:00:00Z],
        timezone: "UTC",
        conference_data: %{
          createRequest: %{
            requestId: "req-abc",
            conferenceSolutionKey: %{type: "hangoutsMeet"}
          }
        }
      }

      result = EventMapper.format_event_data(event_data)

      assert result["conferenceData"] == %{
               "createRequest" => %{
                 "requestId" => "req-abc",
                 "conferenceSolutionKey" => %{"type" => "hangoutsMeet"}
               }
             }
    end

    test "omits conferenceData when :conference_data is absent" do
      event_data = %{
        summary: "Plain Meeting",
        start_time: ~U[2026-06-01 09:00:00Z],
        end_time: ~U[2026-06-01 10:00:00Z],
        timezone: "UTC"
      }

      result = EventMapper.format_event_data(event_data)

      refute Map.has_key?(result, "conferenceData")
    end
  end

  describe "requires_conference_data_version?/1" do
    test "returns true when :conference_data is a non-empty map" do
      assert EventMapper.requires_conference_data_version?(%{
               conference_data: %{createRequest: %{}}
             })
    end

    test "returns false when :conference_data is absent" do
      refute EventMapper.requires_conference_data_version?(%{summary: "no conf"})
    end

    test "returns false when :conference_data is an empty map" do
      refute EventMapper.requires_conference_data_version?(%{conference_data: %{}})
    end
  end

  describe "format_event_data/1 — reminders" do
    test "maps reminders to non-default overrides with method and minutes" do
      event_data = %{
        summary: "Meeting",
        start_time: ~U[2026-04-18 10:00:00Z],
        end_time: ~U[2026-04-18 11:00:00Z],
        reminders: [
          %{method: :popup, minutes_before: 10},
          %{method: :email, minutes_before: 60}
        ]
      }

      result = EventMapper.format_event_data(event_data)

      assert result["reminders"]["useDefault"] == false

      assert result["reminders"]["overrides"] == [
               %{"method" => "popup", "minutes" => 10},
               %{"method" => "email", "minutes" => 60}
             ]
    end

    test "omits the reminders key when no reminders are present" do
      event_data = %{
        summary: "Meeting",
        start_time: ~U[2026-04-18 10:00:00Z],
        end_time: ~U[2026-04-18 11:00:00Z]
      }

      result = EventMapper.format_event_data(event_data)

      refute Map.has_key?(result, "reminders")
    end

    test "omits the reminders key for an empty reminders list" do
      event_data = %{
        summary: "Meeting",
        start_time: ~U[2026-04-18 10:00:00Z],
        end_time: ~U[2026-04-18 11:00:00Z],
        reminders: []
      }

      result = EventMapper.format_event_data(event_data)

      refute Map.has_key?(result, "reminders")
    end
  end

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

    test "omits the recurrence key when no rule is present" do
      event_data = %{
        summary: "Once",
        start_time: ~U[2026-04-18 10:00:00Z],
        end_time: ~U[2026-04-18 11:00:00Z]
      }

      result = EventMapper.format_event_data(event_data)

      refute Map.has_key?(result, "recurrence")
    end
  end
end
