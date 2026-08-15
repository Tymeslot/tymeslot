defmodule Tymeslot.Integrations.Calendar.SyncLink.MirrorPayloadTest do
  @moduledoc """
  The `busy_only` placeholder payload.

  Two things are pinned here. The first is that nothing leaks: no description,
  no location, no attendees, no conferencing link, whatever the source carried.
  A placeholder that quietly copies a meeting title onto the organiser's work
  calendar is the failure this whole privacy tier exists to prevent.

  The second is the all-day branch. All-day rows leave `start_at`/`end_at` NULL
  and carry `start_date`/`end_date` instead — the 20260408110831 migration
  dropped those NOT NULL constraints for exactly that reason. A payload builder
  reading `start_at` unconditionally therefore produces `nil` for every all-day
  source, and every provider mapper keys off `%Date{}` in `start_time` to decide
  the event is all-day, so the mistake shows up as an invalid DTSTART rather
  than as a wrong-but-plausible time.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :sync_links

  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.SyncLink.MirrorPayload

  @target_uid "tymeslot-mirror-abc123"

  defp timed_event(attrs \\ %{}) do
    CalendarEvent.new!(
      Map.merge(
        %{
          uid: "source-uid",
          calendar_integration_id: 7,
          provider: :google,
          provider_calendar_id: "primary",
          provider_event_id: "pid-1",
          summary: "Quarterly review with the board",
          description: "Agenda attached, discuss the redundancies",
          location: "Room 4, 12 Example Street",
          all_day: false,
          start_at: ~U[2026-07-03 09:30:00Z],
          end_at: ~U[2026-07-03 10:45:00Z],
          timezone: "Europe/Tallinn",
          synced_at: ~U[2026-07-01 00:00:00Z]
        },
        attrs
      )
    )
  end

  defp all_day_event(attrs \\ %{}) do
    CalendarEvent.new!(
      Map.merge(
        %{
          uid: "source-uid",
          calendar_integration_id: 7,
          provider: :google,
          provider_calendar_id: "primary",
          provider_event_id: "pid-1",
          summary: "Annual leave",
          all_day: true,
          start_date: ~D[2026-07-03],
          end_date: ~D[2026-07-04],
          timezone: "Europe/Tallinn",
          synced_at: ~U[2026-07-01 00:00:00Z]
        },
        attrs
      )
    )
  end

  describe "build/2 — timed events" do
    test "carries the source's instants and timezone" do
      payload = MirrorPayload.build(timed_event(), @target_uid)

      assert payload.uid == @target_uid
      assert payload.all_day == false
      assert payload.start_time == ~U[2026-07-03 09:30:00Z]
      assert payload.end_time == ~U[2026-07-03 10:45:00Z]
      assert payload.timezone == "Europe/Tallinn"
    end

    test "the title is the opaque placeholder, never the source's summary" do
      payload = MirrorPayload.build(timed_event(), @target_uid)

      assert payload.summary == "Busy"
    end

    test "no detail from the source reaches the placeholder" do
      payload = MirrorPayload.build(timed_event(), @target_uid)

      refute Map.has_key?(payload, :description)
      refute Map.has_key?(payload, :location)
      refute Map.has_key?(payload, :attendees)
      refute Map.has_key?(payload, :attendee_email)
      refute Map.has_key?(payload, :conference_url)
      refute Map.has_key?(payload, :conference_data)

      encoded = inspect(payload)
      refute encoded =~ "Quarterly review"
      refute encoded =~ "redundancies"
      refute encoded =~ "Example Street"
    end

    test "the placeholder is opaque, so it blocks time on the target" do
      payload = MirrorPayload.build(timed_event(), @target_uid)

      assert payload.transparency == :opaque
    end
  end

  describe "build/2 — all-day events" do
    test "populates the date fields and leaves the instants absent" do
      payload = MirrorPayload.build(all_day_event(), @target_uid)

      assert payload.all_day == true
      assert payload.start_time == ~D[2026-07-03]
      assert payload.end_time == ~D[2026-07-04]

      refute match?(%DateTime{}, payload.start_time)
      refute match?(%DateTime{}, payload.end_time)
    end

    test "a multi-day all-day source keeps its whole span" do
      multi_day = all_day_event(%{start_date: ~D[2026-07-03], end_date: ~D[2026-07-10]})
      payload = MirrorPayload.build(multi_day, @target_uid)

      assert payload.start_time == ~D[2026-07-03]
      assert payload.end_time == ~D[2026-07-10]
    end

    test "carries the source timezone through" do
      payload = MirrorPayload.build(all_day_event(), @target_uid)

      assert payload.timezone == "Europe/Tallinn"
    end

    test "the title is the placeholder here too" do
      payload = MirrorPayload.build(all_day_event(), @target_uid)

      assert payload.summary == "Busy"
      refute inspect(payload) =~ "Annual leave"
    end
  end

  describe "build/2 — cache rows" do
    test "reads the same fields off a ProviderCalendarEventSchema row" do
      row = %Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema{
        uid: "source-uid",
        calendar_integration_id: 7,
        summary: "Annual leave",
        all_day: true,
        start_date: ~D[2026-07-03],
        end_date: ~D[2026-07-04],
        timezone: "Europe/Tallinn"
      }

      payload = MirrorPayload.build(row, @target_uid)

      assert payload.uid == @target_uid
      assert payload.all_day == true
      assert payload.start_time == ~D[2026-07-03]
      assert payload.summary == "Busy"
    end
  end
end
