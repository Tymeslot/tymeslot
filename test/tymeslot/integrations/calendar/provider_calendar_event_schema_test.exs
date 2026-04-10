defmodule Tymeslot.Integrations.Calendar.CalendarEventCacheSchemaTest do
  use ExUnit.Case, async: true

  @moduletag :unit
  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema

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
