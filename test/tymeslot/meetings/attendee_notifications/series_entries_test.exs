defmodule Tymeslot.Meetings.AttendeeNotifications.SeriesEntriesTest do
  use Tymeslot.DataCase, async: true

  @moduletag :meetings
  @moduletag :notifications

  import Tymeslot.Factory

  alias Tymeslot.Meetings.AttendeeNotifications.SeriesEntries
  alias Tymeslot.Meetings.AttendeeNotifications.SeriesEntrySchema

  @start ~U[2026-11-10 09:30:00.000000Z]
  @cutoff ~U[2026-01-01 00:00:00Z]

  setup do
    %{integration: insert(:calendar_integration, provider: "google")}
  end

  describe "record/2" do
    test "a later entry replaces the timing but never lowers the SEQUENCE", %{
      integration: integration
    } do
      event = occurrence(integration)
      later = DateTime.add(@start, 1, :hour)

      SeriesEntries.record(event, [entry("e-1", @start, 5)])
      SeriesEntries.record(event, [entry("e-1", later, 1)])

      assert [%{uid: "e-1", start: ^later, sent_sequence: 5}] = SeriesEntries.recorded(event)
    end

    test "a higher SEQUENCE replaces the one recorded", %{integration: integration} do
      event = occurrence(integration)

      SeriesEntries.record(event, [entry("e-1", @start, 2)])
      SeriesEntries.record(event, [entry("e-1", @start, 4)])

      assert SeriesEntries.sent_sequence(event, "e-1") == 4
    end
  end

  describe "forget_stale/1" do
    test "forgets a series with no cached occurrence whose entries all ended before the cutoff",
         %{integration: integration} do
      gone = occurrence(integration, ~U[2025-06-03 09:30:00Z])
      SeriesEntries.record(gone, [entry("old", ~U[2025-06-03 09:30:00Z], 1)])
      written_long_ago()
      Repo.delete!(gone)

      assert SeriesEntries.forget_stale(@cutoff) == 1
      assert SeriesEntries.recorded(gone) == []
    end

    test "keeps a series whose cache still holds an occurrence, however old its entries", %{
      integration: integration
    } do
      live = occurrence(integration, ~U[2025-06-03 09:30:00Z])
      SeriesEntries.record(live, [entry("first", ~U[2025-06-03 09:30:00Z], 3)])

      assert SeriesEntries.forget_stale(@cutoff) == 0
      assert [%{uid: "first"}] = SeriesEntries.recorded(live)
    end

    test "keeps a series whose rows are gone while one of its entries is still reached", %{
      integration: integration
    } do
      # A write to the whole series has dropped its rows until the next sync.
      dropped = occurrence(integration)

      SeriesEntries.record(dropped, [
        entry("first", ~U[2025-06-03 09:30:00Z], 1),
        entry("recent", @start, 2)
      ])

      Repo.delete!(dropped)

      assert SeriesEntries.forget_stale(@cutoff) == 0
      assert length(SeriesEntries.recorded(dropped)) == 2
    end

    test "keeps a series whose old entries were written since the cutoff", %{
      integration: integration
    } do
      gone = occurrence(integration, ~U[2025-06-03 09:30:00Z])
      SeriesEntries.record(gone, [entry("old", ~U[2025-06-03 09:30:00Z], 1)])
      Repo.delete!(gone)

      assert SeriesEntries.forget_stale(@cutoff) == 0
      assert [%{uid: "old"}] = SeriesEntries.recorded(gone)
    end

    test "keeps a series held while its rows are gone, however long ago its entries were sent",
         %{integration: integration} do
      series = occurrence(integration, ~U[2025-06-03 09:30:00Z])
      SeriesEntries.record(series, [entry("first", ~U[2025-06-03 09:30:00Z], 4)])
      written_long_ago()

      assert :ok = SeriesEntries.hold(integration.id, {:master, "master-g"})
      Repo.delete!(series)

      assert SeriesEntries.forget_stale(@cutoff) == 0
      assert [%{uid: "first", sent_sequence: 4}] = SeriesEntries.recorded(series)
    end

    test "matches a CalDAV series by its resource" do
      caldav = insert(:calendar_integration, provider: "caldav")

      resource =
        insert(:provider_calendar_event,
          calendar_integration: caldav,
          provider: "caldav",
          uid: "res-uid_20250603T093000Z",
          provider_event_id: "/cal/res.ics",
          recurrence_rule: "FREQ=WEEKLY",
          provider_metadata: %{"uid" => "res-uid"},
          start_at: ~U[2025-06-03 09:30:00.000000Z],
          end_at: ~U[2025-06-03 10:30:00.000000Z]
        )

      SeriesEntries.record(resource, [entry("res-uid", ~U[2025-06-03 09:30:00Z], 1)])
      written_long_ago()
      assert [_kept] = SeriesEntries.recorded(resource)
      assert SeriesEntries.forget_stale(@cutoff) == 0

      Repo.delete!(resource)
      assert SeriesEntries.forget_stale(@cutoff) == 1
    end
  end

  defp occurrence(integration, start \\ @start) do
    stamp = Calendar.strftime(start, "%Y%m%dT%H%M%SZ")

    insert(:provider_calendar_event,
      calendar_integration: integration,
      provider: "google",
      uid: "series-g_#{stamp}",
      provider_event_id: "master-g_#{stamp}",
      recurring_event_id: "master-g",
      recurrence_rule: "FREQ=WEEKLY;BYDAY=TU",
      start_at: start,
      end_at: DateTime.add(start, 1, :hour)
    )
  end

  # Entries recorded before the cutoff, as a series emailed about long ago
  # has them.
  defp written_long_ago,
    do: Repo.update_all(SeriesEntrySchema, set: [updated_at: ~U[2025-06-03 10:30:00Z]])

  defp entry(uid, start, sequence),
    do: %{uid: uid, start: start, end: DateTime.add(start, 1, :hour), sequence: sequence}
end
