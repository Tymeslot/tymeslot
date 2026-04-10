defmodule Tymeslot.Integrations.Calendar.CalendarEventCacheSchemaTest do
  use ExUnit.Case, async: true

  @moduletag :unit
  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema

  describe "from_calendar_event/1" do
    test "converts atom provider, transparency, and status to strings" do
      event = base_calendar_event(%{provider: :google, transparency: :opaque, status: :confirmed})
      attrs = ProviderCalendarEventSchema.from_calendar_event(event)
      assert attrs.provider == "google"
      assert attrs.transparency == "opaque"
      assert attrs.status == "confirmed"
    end

    test "converts atom visibility to string" do
      event = base_calendar_event(%{visibility: :private})
      attrs = ProviderCalendarEventSchema.from_calendar_event(event)
      assert attrs.visibility == "private"
    end

    test "preserves nil optional fields as nil" do
      event =
        base_calendar_event(%{
          visibility: nil,
          colour: nil,
          description: nil,
          location: nil,
          timezone: nil,
          provider_updated_at: nil
        })

      attrs = ProviderCalendarEventSchema.from_calendar_event(event)
      assert is_nil(attrs.visibility)
      assert is_nil(attrs.colour)
      assert is_nil(attrs.description)
      assert is_nil(attrs.location)
      assert is_nil(attrs.timezone)
      assert is_nil(attrs.provider_updated_at)
    end

    test "upgrades datetime precision to microsecond for start_at and end_at" do
      # DateTime with second precision (microsecond = {0, 0})
      start_at = ~U[2026-06-10 10:00:00Z]
      end_at = ~U[2026-06-10 11:00:00Z]

      event = base_calendar_event(%{start_at: start_at, end_at: end_at})
      attrs = ProviderCalendarEventSchema.from_calendar_event(event)

      assert {_us, 6} = attrs.start_at.microsecond
      assert {_us, 6} = attrs.end_at.microsecond
    end

    test "passes through datetime with microsecond precision unchanged" do
      start_at = ~U[2026-06-10 10:00:00.123456Z]
      event = base_calendar_event(%{start_at: start_at})
      attrs = ProviderCalendarEventSchema.from_calendar_event(event)
      assert attrs.start_at == start_at
    end
  end

  describe "to_calendar_event/1" do
    test "converts known atom strings to atoms" do
      record = base_record(%{transparency: "opaque", status: "confirmed"})
      event = ProviderCalendarEventSchema.to_calendar_event(record)
      assert event.transparency == :opaque
      assert event.status == :confirmed
    end

    test "falls back to :opaque for unknown transparency string" do
      record = base_record(%{transparency: "not_a_real_transparency_value"})
      event = ProviderCalendarEventSchema.to_calendar_event(record)
      assert event.transparency == :opaque
    end

    test "falls back to :confirmed for unknown status string" do
      record = base_record(%{status: "not_a_real_status_value"})
      event = ProviderCalendarEventSchema.to_calendar_event(record)
      assert event.status == :confirmed
    end

    test "returns nil for unknown visibility string" do
      record = base_record(%{visibility: "not_a_real_visibility_value"})
      event = ProviderCalendarEventSchema.to_calendar_event(record)
      assert event.visibility == nil
    end

    test "preserves nil visibility" do
      record = base_record(%{visibility: nil})
      event = ProviderCalendarEventSchema.to_calendar_event(record)
      assert event.visibility == nil
    end
  end

  defp base_calendar_event(overrides) do
    now = ~U[2026-04-08 10:00:00.000000Z]

    fields =
      Map.merge(
        %{
          uid: "test-uid-1",
          calendar_integration_id: 1,
          provider: :google,
          provider_calendar_id: "primary",
          provider_event_id: nil,
          recurring_event_id: nil,
          summary: nil,
          description: nil,
          location: nil,
          visibility: nil,
          colour: nil,
          all_day: false,
          start_date: nil,
          end_date: nil,
          start_at: now,
          end_at: DateTime.add(now, 3600, :second),
          timezone: "UTC",
          transparency: :opaque,
          status: :confirmed,
          organiser: nil,
          attendees: [],
          recurrence_rule: nil,
          recurrence_exceptions: [],
          attachments: [],
          links: [],
          reminders: [],
          etag: nil,
          synced_at: ~U[2026-04-08 09:00:00.000000Z],
          provider_updated_at: nil,
          provider_metadata: %{}
        },
        overrides
      )

    struct!(Tymeslot.Integrations.Calendar.CalendarEvent, fields)
  end

  defp base_record(overrides) do
    fields =
      Map.merge(
        %{
          uid: "test-uid-1",
          calendar_integration_id: 1,
          provider: "google",
          provider_calendar_id: "primary",
          provider_event_id: nil,
          recurring_event_id: nil,
          summary: nil,
          description: nil,
          location: nil,
          visibility: nil,
          colour: nil,
          all_day: false,
          start_date: nil,
          end_date: nil,
          start_at: ~U[2026-04-08 10:00:00Z],
          end_at: ~U[2026-04-08 10:30:00Z],
          timezone: "UTC",
          transparency: "opaque",
          status: "confirmed",
          organiser: nil,
          attendees: [],
          recurrence_rule: nil,
          recurrence_exceptions: [],
          attachments: [],
          links: [],
          reminders: [],
          etag: nil,
          synced_at: ~U[2026-04-08 09:00:00.000000Z],
          provider_updated_at: nil,
          provider_metadata: %{}
        },
        overrides
      )

    struct!(ProviderCalendarEventSchema, fields)
  end
end
