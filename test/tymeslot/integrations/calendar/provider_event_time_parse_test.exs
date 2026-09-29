defmodule Tymeslot.Integrations.Calendar.ProviderEventTimeParseTest do
  @moduledoc """
  The Google and Outlook providers read an event time they cannot parse as
  missing. That is logged with the provider and the field, and nothing of the
  event's content. Outlook's opaque Graph id is logged too; Google's is not,
  since for an event this application created it is derived from the meeting
  uid, which authorises cancelling the booking.
  """

  # async: false: the capture handler sees every process's log events, and
  # these tests match on a message other provider tests could also produce.
  use ExUnit.Case, async: false

  @moduletag :integrations
  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.Google.Provider, as: GoogleProvider
  alias Tymeslot.Integrations.Calendar.Outlook.Provider, as: OutlookProvider
  alias Tymeslot.Test.LogCapture

  @message "Could not parse a calendar event time"

  setup do
    LogCapture.attach()
    :ok
  end

  test "Google: an unparseable start is logged and read as missing" do
    event =
      GoogleProvider.convert_event(%{
        "id" => "google-evt-1",
        "summary" => "Private summary",
        "start" => %{"dateTime" => "not a time"},
        "end" => %{"dateTime" => "2026-10-01T10:00:00Z"}
      })

    assert event.start_time == nil
    assert event.end_time == ~U[2026-10-01 10:00:00Z]

    log = LogCapture.await_log(@message)
    assert log.level == :warning

    meta = LogCapture.user_metadata(log)
    assert %{provider: :google, field: "start", reason: :invalid_format} = meta
    refute Map.has_key?(meta, :event_id)

    refute inspect(LogCapture.user_metadata(log)) =~ "Private summary"
  end

  test "Google: an unparseable all-day date is logged and read as missing" do
    event =
      GoogleProvider.convert_event(%{
        "id" => "google-evt-2",
        "start" => %{"date" => "2026-10-01"},
        "end" => %{"date" => "2026-13-45"}
      })

    assert event.end_time == nil

    log = LogCapture.await_log(@message)
    assert %{provider: :google, field: "end"} = log.meta
    refute Map.has_key?(log.meta, :event_id)
  end

  test "Outlook: an unparseable start is logged and read as missing" do
    event =
      OutlookProvider.convert_event(%{
        id: "outlook-evt-1",
        summary: "Private summary",
        is_all_day: false,
        start: %{"dateTime" => "not a time", "timeZone" => "UTC"},
        end: %{"dateTime" => "2026-10-01T10:00:00", "timeZone" => "UTC"}
      })

    assert event.start_time == nil
    assert event.end_time == ~U[2026-10-01 10:00:00Z]

    log = LogCapture.await_log(@message)
    assert log.level == :warning

    assert %{
             provider: :outlook,
             event_id: "outlook-evt-1",
             field: "start",
             reason: :invalid_format
           } =
             LogCapture.user_metadata(log)

    refute inspect(LogCapture.user_metadata(log)) =~ "Private summary"
  end

  test "Outlook: an unparseable all-day date is logged and read as missing" do
    event =
      OutlookProvider.convert_event(%{
        id: "outlook-evt-2",
        is_all_day: true,
        start: %{"dateTime" => "2026-10-01T00:00:00.0000000"},
        end: %{"dateTime" => "garbage-date"}
      })

    assert event.end_time == nil

    log = LogCapture.await_log(@message)
    assert %{provider: :outlook, event_id: "outlook-evt-2", field: "end"} = log.meta
  end
end
