defmodule Tymeslot.Integrations.Calendar.CalendarEventTest do
  use ExUnit.Case, async: true

  @moduletag :unit

  alias Tymeslot.Integrations.Calendar.CalendarEvent

  describe "new/1" do
    test "creates a valid timed event" do
      attrs = %{
        uid: "test-123",
        calendar_integration_id: 1,
        provider: :google,
        provider_calendar_id: "primary",
        provider_event_id: "google-evt-123",
        summary: "Team Standup",
        all_day: false,
        start_at: ~U[2026-04-08 10:00:00Z],
        end_at: ~U[2026-04-08 10:30:00Z],
        timezone: "Europe/London",
        transparency: :opaque,
        status: :confirmed,
        synced_at: ~U[2026-04-08 09:00:00Z]
      }

      assert {:ok, %CalendarEvent{} = event} = CalendarEvent.new(attrs)
      assert event.uid == "test-123"
      assert event.summary == "Team Standup"
      assert event.all_day == false
      assert event.start_at == ~U[2026-04-08 10:00:00Z]
      assert event.transparency == :opaque
      assert event.status == :confirmed
      assert event.attendees == []
      assert event.reminders == []
      assert event.provider_metadata == %{}
      assert event.created_by_tymeslot == false
    end

    test "creates a valid all-day event" do
      attrs = %{
        uid: "allday-456",
        calendar_integration_id: 1,
        provider: :caldav,
        provider_calendar_id: "/cal/personal",
        all_day: true,
        start_date: ~D[2026-04-08],
        end_date: ~D[2026-04-09],
        synced_at: ~U[2026-04-08 09:00:00Z]
      }

      assert {:ok, %CalendarEvent{} = event} = CalendarEvent.new(attrs)
      assert event.all_day == true
      assert event.start_date == ~D[2026-04-08]
      assert event.end_date == ~D[2026-04-09]
      assert event.start_at == nil
      assert event.end_at == nil
      assert event.transparency == :opaque
      assert event.status == :confirmed
    end

    test "rejects all-day event with start_at set" do
      attrs = %{
        uid: "bad-allday",
        calendar_integration_id: 1,
        provider: :google,
        provider_calendar_id: "primary",
        all_day: true,
        start_date: ~D[2026-04-08],
        end_date: ~D[2026-04-09],
        start_at: ~U[2026-04-08 10:00:00Z],
        synced_at: ~U[2026-04-08 09:00:00Z]
      }

      assert {:error, _reason} = CalendarEvent.new(attrs)
    end

    test "rejects timed event with start_date set" do
      attrs = %{
        uid: "bad-timed",
        calendar_integration_id: 1,
        provider: :google,
        provider_calendar_id: "primary",
        all_day: false,
        start_at: ~U[2026-04-08 10:00:00Z],
        end_at: ~U[2026-04-08 10:30:00Z],
        start_date: ~D[2026-04-08],
        synced_at: ~U[2026-04-08 09:00:00Z]
      }

      assert {:error, _reason} = CalendarEvent.new(attrs)
    end

    test "rejects missing uid" do
      attrs = %{
        calendar_integration_id: 1,
        provider: :google,
        provider_calendar_id: "primary",
        all_day: false,
        start_at: ~U[2026-04-08 10:00:00Z],
        end_at: ~U[2026-04-08 10:30:00Z],
        synced_at: ~U[2026-04-08 09:00:00Z]
      }

      assert {:error, _reason} = CalendarEvent.new(attrs)
    end

    test "rejects empty uid" do
      attrs = %{
        uid: "",
        calendar_integration_id: 1,
        provider: :google,
        provider_calendar_id: "primary",
        all_day: false,
        start_at: ~U[2026-04-08 10:00:00Z],
        end_at: ~U[2026-04-08 10:30:00Z],
        synced_at: ~U[2026-04-08 09:00:00Z]
      }

      assert {:error, _reason} = CalendarEvent.new(attrs)
    end

    test "rejects timed event missing start_at" do
      attrs = %{
        uid: "no-start",
        calendar_integration_id: 1,
        provider: :google,
        provider_calendar_id: "primary",
        all_day: false,
        end_at: ~U[2026-04-08 10:30:00Z],
        synced_at: ~U[2026-04-08 09:00:00Z]
      }

      assert {:error, _reason} = CalendarEvent.new(attrs)
    end

    test "rejects all-day event missing start_date" do
      attrs = %{
        uid: "no-date",
        calendar_integration_id: 1,
        provider: :google,
        provider_calendar_id: "primary",
        all_day: true,
        end_date: ~D[2026-04-09],
        synced_at: ~U[2026-04-08 09:00:00Z]
      }

      assert {:error, _reason} = CalendarEvent.new(attrs)
    end

    test "rejects google event without provider_event_id" do
      attrs = %{
        uid: "google-no-event-id",
        calendar_integration_id: 1,
        provider: :google,
        provider_calendar_id: "primary",
        all_day: false,
        start_at: ~U[2026-04-08 10:00:00Z],
        end_at: ~U[2026-04-08 10:30:00Z],
        synced_at: ~U[2026-04-08 09:00:00Z]
      }

      assert {:error, reason} = CalendarEvent.new(attrs)
      assert reason =~ "provider_event_id"
    end

    test "rejects google event with empty provider_event_id" do
      attrs = %{
        uid: "google-empty-event-id",
        calendar_integration_id: 1,
        provider: :google,
        provider_calendar_id: "primary",
        provider_event_id: "",
        all_day: false,
        start_at: ~U[2026-04-08 10:00:00Z],
        end_at: ~U[2026-04-08 10:30:00Z],
        synced_at: ~U[2026-04-08 09:00:00Z]
      }

      assert {:error, reason} = CalendarEvent.new(attrs)
      assert reason =~ "provider_event_id"
    end

    test "rejects outlook event without provider_event_id" do
      attrs = %{
        uid: "outlook-no-event-id",
        calendar_integration_id: 1,
        provider: :outlook,
        provider_calendar_id: "AAMkAG...",
        all_day: false,
        start_at: ~U[2026-04-08 10:00:00Z],
        end_at: ~U[2026-04-08 10:30:00Z],
        synced_at: ~U[2026-04-08 09:00:00Z]
      }

      assert {:error, reason} = CalendarEvent.new(attrs)
      assert reason =~ "provider_event_id"
    end

    test "accepts caldav event without provider_event_id" do
      attrs = %{
        uid: "caldav-no-event-id",
        calendar_integration_id: 1,
        provider: :caldav,
        provider_calendar_id: "/cal/personal",
        all_day: false,
        start_at: ~U[2026-04-08 10:00:00Z],
        end_at: ~U[2026-04-08 10:30:00Z],
        synced_at: ~U[2026-04-08 09:00:00Z]
      }

      assert {:ok, %CalendarEvent{}} = CalendarEvent.new(attrs)
    end
  end

  describe "new!/1" do
    test "returns struct on valid input" do
      attrs = %{
        uid: "bang-test",
        calendar_integration_id: 1,
        provider: :google,
        provider_calendar_id: "primary",
        provider_event_id: "google-evt-bang",
        all_day: false,
        start_at: ~U[2026-04-08 10:00:00Z],
        end_at: ~U[2026-04-08 10:30:00Z],
        synced_at: ~U[2026-04-08 09:00:00Z]
      }

      assert %CalendarEvent{uid: "bang-test"} = CalendarEvent.new!(attrs)
    end

    test "raises on invalid input" do
      assert_raise ArgumentError, fn ->
        CalendarEvent.new!(%{uid: ""})
      end
    end
  end

  describe "blocking?/1" do
    test "confirmed opaque event blocks" do
      {:ok, event} = build_timed_event(%{status: :confirmed, transparency: :opaque})
      assert CalendarEvent.blocking?(event)
    end

    test "tentative opaque event blocks" do
      {:ok, event} = build_timed_event(%{status: :tentative, transparency: :opaque})
      assert CalendarEvent.blocking?(event)
    end

    test "cancelled event does not block" do
      {:ok, event} = build_timed_event(%{status: :cancelled})
      refute CalendarEvent.blocking?(event)
    end

    test "declined event does not block" do
      {:ok, event} = build_timed_event(%{status: :declined})
      refute CalendarEvent.blocking?(event)
    end

    test "transparent event does not block" do
      {:ok, event} = build_timed_event(%{transparency: :transparent})
      refute CalendarEvent.blocking?(event)
    end

    test "transparent cancelled event does not block" do
      {:ok, event} = build_timed_event(%{status: :cancelled, transparency: :transparent})
      refute CalendarEvent.blocking?(event)
    end

    defp build_timed_event(overrides) do
      base = %{
        uid: "blocking-test-#{System.unique_integer([:positive])}",
        calendar_integration_id: 1,
        provider: :google,
        provider_calendar_id: "primary",
        provider_event_id: "google-evt-blocking",
        all_day: false,
        start_at: ~U[2026-04-08 10:00:00Z],
        end_at: ~U[2026-04-08 10:30:00Z],
        synced_at: ~U[2026-04-08 09:00:00Z]
      }

      CalendarEvent.new(Map.merge(base, overrides))
    end
  end
end
