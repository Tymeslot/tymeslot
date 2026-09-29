defmodule Tymeslot.Integrations.Calendar.InvalidEventReportTest do
  # `capture_admin_alerts` points the global alert implementation at this
  # process, and the absence assertions below would trip over another
  # module's alert, so this cannot run async.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Tymeslot.AdminAlertsCaptureHelpers

  @moduletag :calendar
  @moduletag :unit

  setup :capture_admin_alerts

  alias Tymeslot.Infrastructure.AdminAlerts.AlertTypes
  alias Tymeslot.Integrations.Calendar.Google.EventNormaliser, as: GoogleNormaliser
  alias Tymeslot.Integrations.Calendar.ICalNormaliser
  alias Tymeslot.Integrations.Calendar.InvalidEventReport
  alias Tymeslot.Integrations.Calendar.Outlook.EventNormaliser, as: OutlookNormaliser

  @context %{
    calendar_integration_id: 7,
    provider_calendar_id: "cal",
    synced_at: ~U[2030-06-01 00:00:00Z]
  }

  defp ical_valid(uid) do
    %{
      uid: uid,
      summary: "Good",
      dtstart: ~U[2030-06-15 09:00:00Z],
      dtend: ~U[2030-06-15 10:00:00Z]
    }
  end

  # A timed event with no start: `CalendarEvent.new/1` rejects it.
  defp ical_invalid(uid), do: %{uid: uid, summary: "Bad", dtend: ~U[2030-06-15 10:00:00Z]}

  defp normalise_ical(raw_events) do
    capture_log(fn ->
      send(self(), {:result, ICalNormaliser.normalise_events(raw_events, @context, :caldav)})
    end)

    assert_received {:result, result}
    result
  end

  describe "collect/1" do
    test "a run with three invalid events raises one alert carrying all three" do
      raw = [
        ical_valid("good-1"),
        ical_invalid("bad-1"),
        ical_invalid("bad-2"),
        ical_valid("good-2"),
        ical_invalid("bad-3")
      ]

      {:ok, events} = InvalidEventReport.collect(fn -> normalise_ical(raw) end)

      assert Enum.map(events, & &1.uid) == ["good-1", "good-2"]

      assert_received {:send_alert, :invalid_calendar_event, payload}
      refute_received {:send_alert, :invalid_calendar_event, _second}

      assert payload.count == 3
      assert payload.provider == :caldav
      assert payload.calendar_integration_id == 7
      assert payload.sample_events =~ ~r/^bad-1 \(.+\); bad-2 \(.+\); bad-3 \(.+\)$/
      assert payload.reason_message =~ "timed events require DateTime values"

      message = AlertTypes.format_message(:invalid_calendar_event, payload)
      assert message =~ "3 invalid caldav calendar event(s) skipped for integration 7"
    end

    test "invalid events across several normalise calls of one run raise one alert" do
      InvalidEventReport.collect(fn ->
        normalise_ical([ical_invalid("bad-1")])
        normalise_ical([ical_invalid("bad-2"), ical_valid("good")])
      end)

      assert_received {:send_alert, :invalid_calendar_event, %{count: 2}}
      refute_received {:send_alert, :invalid_calendar_event, _second}
    end

    test "names at most five sample events however many were skipped" do
      raw = Enum.map(1..8, &ical_invalid("bad-#{&1}"))

      InvalidEventReport.collect(fn -> normalise_ical(raw) end)

      assert_received {:send_alert, :invalid_calendar_event, payload}
      assert payload.count == 8

      assert payload.sample_events |> String.split("; ") |> Enum.map(&hd(String.split(&1))) ==
               ~w(bad-1 bad-2 bad-3 bad-4 bad-5)
    end

    test "the alert's reason is the most common one in the run" do
      InvalidEventReport.collect(fn ->
        InvalidEventReport.record(:caldav, @context, "a", "uid is required")
        InvalidEventReport.record(:caldav, @context, "b", "start is required")
        InvalidEventReport.record(:caldav, @context, "c", "start is required")
      end)

      assert_received {:send_alert, :invalid_calendar_event, payload}
      assert payload.reason_message == "start is required"
      assert payload.reasons == "start is required; uid is required"
    end

    test "raises one alert per integration skipped in the run" do
      InvalidEventReport.collect(fn ->
        InvalidEventReport.record(:caldav, @context, "a", "uid is required")
        InvalidEventReport.record(:caldav, %{@context | calendar_integration_id: 8}, "b", "x")
      end)

      assert_received {:send_alert, :invalid_calendar_event, %{calendar_integration_id: 7}}
      assert_received {:send_alert, :invalid_calendar_event, %{calendar_integration_id: 8}}
    end

    test "a nested collection is reported once, by the outermost" do
      InvalidEventReport.collect(fn ->
        InvalidEventReport.collect(fn ->
          InvalidEventReport.record(:caldav, @context, "a", "uid is required")
        end)

        refute_received {:send_alert, :invalid_calendar_event, _early}
        InvalidEventReport.record(:caldav, @context, "b", "uid is required")
      end)

      assert_received {:send_alert, :invalid_calendar_event, %{count: 2}}
    end

    test "reports what was skipped before the run raised" do
      assert_raise RuntimeError, fn ->
        InvalidEventReport.collect(fn ->
          InvalidEventReport.record(:caldav, @context, "a", "uid is required")
          raise "sync failed"
        end)
      end

      assert_received {:send_alert, :invalid_calendar_event, %{count: 1}}
    end

    test "returns the run's result and raises nothing for a clean run" do
      assert {:ok, [_event]} =
               InvalidEventReport.collect(fn -> normalise_ical([ical_valid("good")]) end)

      refute_received {:send_alert, _type, _payload}
    end
  end

  describe "normalisers outside a collection" do
    test "the iCal normaliser skips an invalid event without alerting" do
      assert {:ok, [%{uid: "good"}]} = normalise_ical([ical_invalid("bad"), ical_valid("good")])

      refute_received {:send_alert, _type, _payload}
    end

    test "the Google normaliser skips an invalid event without alerting" do
      raw = [
        %{"summary" => "No UID"},
        %{
          "iCalUID" => "valid-uid@google.com",
          "id" => "valid-id",
          "start" => %{"dateTime" => "2026-04-08T12:00:00Z"},
          "end" => %{"dateTime" => "2026-04-08T13:00:00Z"}
        }
      ]

      capture_log(fn ->
        assert {:ok, [%{uid: "valid-uid@google.com"}]} =
                 GoogleNormaliser.normalise_events(raw, @context)
      end)

      refute_received {:send_alert, _type, _payload}
    end

    test "the Outlook normaliser skips an invalid event without alerting" do
      raw = [
        %{"id" => nil, "iCalUId" => nil, "subject" => "Bad"},
        %{
          "id" => "graph-id-1",
          "iCalUId" => "ical-uid-1",
          "start" => %{"dateTime" => "2024-03-15T14:00:00Z", "timeZone" => "UTC"},
          "end" => %{"dateTime" => "2024-03-15T15:00:00Z", "timeZone" => "UTC"}
        }
      ]

      capture_log(fn ->
        assert {:ok, [%{uid: "ical-uid-1"}]} = OutlookNormaliser.normalise_events(raw, @context)
      end)

      refute_received {:send_alert, _type, _payload}
    end

    test "the Google normaliser's skips are collected with their event id" do
      InvalidEventReport.collect(fn ->
        capture_log(fn ->
          GoogleNormaliser.normalise_events(
            [%{"id" => "g-1", "summary" => "No start"}],
            @context
          )
        end)
      end)

      assert_received {:send_alert, :invalid_calendar_event, payload}
      assert payload.provider == :google
      assert payload.sample_events =~ "g-1 ("
    end

    test "the Outlook normaliser's skips are collected with their event id" do
      InvalidEventReport.collect(fn ->
        capture_log(fn ->
          OutlookNormaliser.normalise_events(
            [%{"id" => "o-1", "subject" => "No start"}],
            @context
          )
        end)
      end)

      assert_received {:send_alert, :invalid_calendar_event, payload}
      assert payload.provider == :outlook
      assert payload.sample_events =~ "o-1 ("
    end
  end
end
