defmodule Tymeslot.Integrations.Calendar.CalDAV.MixedValueTypeSyncTest do
  @moduledoc """
  Covers VEVENTs whose DTSTART and DTEND disagree on value type, at the
  normaliser and across the whole CalDAV cache path (iCal string → parser →
  normaliser → `Sync.upsert_cache/2`).

  RFC 5545 requires the pair to share a value type, but producers do emit a
  `VALUE=DATE` DTSTART against a `DATE-TIME` DTEND and the reverse, and the iCal
  parser types each property independently, so the mismatch arrives intact. The
  pair used to reach the batch insert with a `%DateTime{}` in the `:date`-typed
  `end_date` column (or a `%Date{}` in `end_at`). Both raise, and
  `SyncReconciler` runs the upsert inside a transaction that rolls back on any
  error, so a single malformed event silently cost the user every busy time on
  that calendar, on every sync, for as long as the event existed.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :integrations
  @moduletag :integration

  import Ecto.Query

  alias Tymeslot.Integrations.Calendar.CalDAV.EventProcessor
  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.ICalParser
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Integrations.Calendar.Sync
  alias Tymeslot.Repo

  @feed """
  BEGIN:VCALENDAR
  VERSION:2.0
  PRODID:-//Test//Test//EN
  BEGIN:VEVENT
  UID:ordinary@example.com
  DTSTART:20300315T100000Z
  DTEND:20300315T110000Z
  SUMMARY:Ordinary Meeting
  END:VEVENT
  BEGIN:VEVENT
  UID:date-start@example.com
  DTSTART;VALUE=DATE:20300101
  DTEND:20300102T120000Z
  SUMMARY:Mixed - date start
  END:VEVENT
  BEGIN:VEVENT
  UID:date-end@example.com
  DTSTART:20300201T090000Z
  DTEND;VALUE=DATE:20300202
  SUMMARY:Mixed - date end
  END:VEVENT
  END:VCALENDAR
  """

  setup do
    integration = insert(:calendar_integration, provider: "caldav", calendar_paths: ["/cal/"])

    {:ok, integration: integration}
  end

  describe "normalise_events/2" do
    @context %{
      calendar_integration_id: 42,
      provider_calendar_id: "default",
      synced_at: ~U[2026-04-08 12:00:00Z]
    }

    test "a DATE dtstart against a DATE-TIME dtend stays an all-day Date pair" do
      raw = %{
        uid: "mixed-date-start@example.com",
        summary: "Conference",
        dtstart: ~D[2030-01-01],
        dtend: ~U[2030-01-02 12:00:00Z]
      }

      assert {:ok, [%CalendarEvent{} = event]} =
               EventProcessor.normalise_events([raw], @context)

      assert event.all_day == true
      assert %Date{} = event.start_date
      assert %Date{} = event.end_date
      assert event.start_date == ~D[2030-01-01]
      # DTEND is exclusive, and the event runs into the second day, so the
      # exclusive end rounds up rather than truncating that final part-day away.
      assert event.end_date == ~D[2030-01-03]
      assert event.start_at == nil
      assert event.end_at == nil
    end

    test "a midnight DATE-TIME dtend does not gain a spurious extra day" do
      raw = %{
        uid: "mixed-midnight@example.com",
        summary: "Holiday",
        dtstart: ~D[2030-01-01],
        dtend: ~U[2030-01-02 00:00:00Z]
      }

      assert {:ok, [%CalendarEvent{} = event]} =
               EventProcessor.normalise_events([raw], @context)

      assert event.end_date == ~D[2030-01-02]
    end

    test "a DATE-TIME dtstart against a DATE dtend stays a timed DateTime pair" do
      raw = %{
        uid: "mixed-date-end@example.com",
        summary: "Long shift",
        dtstart: ~U[2030-01-01 09:00:00Z],
        dtend: ~D[2030-01-02]
      }

      assert {:ok, [%CalendarEvent{} = event]} =
               EventProcessor.normalise_events([raw], @context)

      assert event.all_day == false
      assert %DateTime{} = event.start_at
      assert %DateTime{} = event.end_at
      assert event.start_at == ~U[2030-01-01 09:00:00Z]
      assert event.end_at == ~U[2030-01-02 00:00:00Z]
      assert event.start_date == nil
      assert event.end_date == nil
    end

    test "a DATE dtend is read in the event's own zone, not as UTC midnight" do
      {:ok, start_at} = DateTime.new(~D[2030-01-01], ~T[09:00:00], "Europe/Berlin")

      raw = %{
        uid: "mixed-zoned@example.com",
        summary: "Berlin shift",
        dtstart: start_at,
        dtend: ~D[2030-01-02]
      }

      assert {:ok, [%CalendarEvent{} = event]} =
               EventProcessor.normalise_events([raw], @context)

      assert event.timezone == "Europe/Berlin"
      # Midnight in Berlin is 23:00 UTC the previous day. Reading the floating
      # date as UTC midnight instead would free the last hour the user is busy.
      assert event.end_at == ~U[2030-01-01 23:00:00Z]
    end
  end

  test "caches every event in a feed that mixes DATE and DATE-TIME", %{
    integration: integration
  } do
    context = %{
      calendar_integration_id: integration.id,
      provider_calendar_id: "/cal/",
      synced_at: DateTime.utc_now()
    }

    assert {:ok, parsed} = ICalParser.parse(@feed)
    assert {:ok, events} = EventProcessor.normalise_events(parsed, context)

    assert {:ok, 3} = Sync.upsert_cache(integration, events)

    cached =
      ProviderCalendarEventSchema
      |> where(calendar_integration_id: ^integration.id)
      |> Repo.all()
      |> Map.new(&{&1.uid, &1})

    assert Enum.sort(Map.keys(cached)) == [
             "date-end@example.com",
             "date-start@example.com",
             "ordinary@example.com"
           ]

    # The ordinary event is unaffected by its malformed neighbours.
    ordinary = cached["ordinary@example.com"]
    assert ordinary.all_day == false
    assert DateTime.compare(ordinary.start_at, ~U[2030-03-15 10:00:00Z]) == :eq

    # Each mixed pair lands in the columns its own value type belongs in.
    date_start = cached["date-start@example.com"]
    assert date_start.all_day == true
    assert date_start.start_date == ~D[2030-01-01]
    assert date_start.end_date == ~D[2030-01-03]
    assert date_start.start_at == nil

    date_end = cached["date-end@example.com"]
    assert date_end.all_day == false
    assert DateTime.compare(date_end.end_at, ~U[2030-02-02 00:00:00Z]) == :eq
    assert date_end.end_date == nil
  end
end
