defmodule Tymeslot.Infrastructure.AdminAlerts.AlertTypesInvalidCalendarEventTest do
  use ExUnit.Case, async: true

  @moduletag :infrastructure
  @moduletag :calendar
  @moduletag :unit

  alias Tymeslot.Infrastructure.AdminAlerts.AlertTypes

  # The shape `InvalidEventReport` sends through `AdminAlerts.report/2` once a
  # sync run ends: one alert per integration, the reason flattened into
  # `reason_code`/`reason_message`.
  @batch %{
    provider: :caldav,
    calendar_integration_id: 7,
    count: 3,
    reason_code: nil,
    reason_message: "uid is required",
    reasons: "missing required fields: [:start_time]; uid is required",
    sample_events: "evt-1 (uid is required); evt-2 (uid is required)",
    summary: "3 invalid caldav calendar event(s) skipped"
  }

  describe "format_message/2" do
    test "a batch names the count, provider, integration, reason and sample events" do
      message = AlertTypes.format_message(:invalid_calendar_event, @batch)

      assert message ==
               "3 invalid caldav calendar event(s) skipped for integration 7 " <>
                 "(most common reason: uid is required). " <>
                 "First skipped: evt-1 (uid is required); evt-2 (uid is required)"
    end

    test "a caller with only a summary gets its summary" do
      assert AlertTypes.format_message(:invalid_calendar_event, %{
               summary: "Calendar audit failed: [google] timed event"
             }) == "Calendar audit failed: [google] timed event"
    end
  end

  describe "dedup_key/2" do
    test "is stable across runs that skipped different events and counts" do
      other_run = %{@batch | count: 40, sample_events: "evt-9999 (uid is required)"}

      assert AlertTypes.dedup_key(:invalid_calendar_event, @batch) ==
               AlertTypes.dedup_key(:invalid_calendar_event, other_run)
    end

    test "differs across providers, integrations and reasons" do
      key = AlertTypes.dedup_key(:invalid_calendar_event, @batch)

      refute key ==
               AlertTypes.dedup_key(:invalid_calendar_event, %{@batch | provider: :google})

      refute key ==
               AlertTypes.dedup_key(:invalid_calendar_event, %{
                 @batch
                 | calendar_integration_id: 8
               })

      refute key ==
               AlertTypes.dedup_key(:invalid_calendar_event, %{
                 @batch
                 | reason_message: "all-day events require Date values"
               })
    end

    test "without an integration keeps the message-based key" do
      metadata = %{provider: :caldav, summary: "Calendar audit failed: [caldav] audit"}

      assert AlertTypes.dedup_key(:invalid_calendar_event, metadata) ==
               AlertTypes.format_message(:invalid_calendar_event, metadata)
    end
  end
end
