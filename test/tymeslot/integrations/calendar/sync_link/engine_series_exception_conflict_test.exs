defmodule Tymeslot.Integrations.Calendar.SyncLink.EngineSeriesExceptionConflictTest do
  @moduledoc """
  What the conflict log says about a mirrored series, now that the placeholder
  carries the master's EXDATE lines.

  Stage B wrote a `series_exceptions` row whenever the master carried any
  exceptions, and it was right to: the placeholder was built from the rule
  alone, so a cancelled occurrence really did go on blocking a slot the
  organiser had freed. Applying the EXDATEs closes that gap, and a row still
  claiming it would send someone looking for a discrepancy that is not there.

  So the assertions here are mostly *absences*, which is the point. The one kind
  that stopped firing must be shown to have stopped, and the kinds that describe
  a divergence still detectable — a write that ran out of attempts — must be
  shown to still fire, because "the log went quiet" and "the log went silent"
  are different outcomes and only the first is wanted.

  A moved occurrence is the divergence that survives all of this, and nothing
  here asserts on it because it is not detectable from where this module looks.
  The engine reads mirror state — a mapping row, a cached placeholder, two
  etags — and a move is in none of it: `upsert_batch/1` collapses the expanded
  instances to one cache row and the moved occurrence's new time is never
  stored. It is detected instead from the uncollapsed batch, before that dedup,
  and covered by `MovedOccurrenceTest`.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :sync_links

  import Mox
  import Tymeslot.SyncLinkTestHelpers

  alias Tymeslot.Integrations.Calendar.CalendarSyncConflictQueries
  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Integrations.Calendar.SyncLink.Engine
  alias Tymeslot.Integrations.Calendar.SyncLink.SeriesMasterCache

  setup :verify_on_exit!

  setup do
    context = linked_pair()
    {:ok, link} = CalendarSyncLinkQueries.get(context.link.id)
    %{context | link: link}
  end

  defp weekly_instance(source, attrs \\ %{}) do
    Map.merge(
      %ProviderCalendarEventSchema{
        uid: "weekly-series@google.com",
        calendar_integration_id: source.id,
        provider: "google",
        provider_calendar_id: "primary",
        provider_event_id: "master_abc123_20261215T090000Z",
        summary: "Weekly standup",
        transparency: "opaque",
        status: "confirmed",
        all_day: false,
        start_at: ~U[2026-12-15 09:00:00Z],
        end_at: ~U[2026-12-15 09:30:00Z],
        recurrence_rule: "RRULE:FREQ=WEEKLY;BYDAY=TU",
        recurring_event_id: "master_abc123"
      },
      attrs
    )
  end

  defp expect_master(recurrence, times \\ 1) do
    expect(GoogleCalendarAPIMock, :get_event, times, fn _integration, _calendar_id, _event_id ->
      {:ok, %{"id" => "master_abc123", "recurrence" => recurrence}}
    end)
  end

  describe "cancelled occurrences are no longer reported as a divergence" do
    test "a master carrying only EXDATEs records no conflict", %{
      user: user,
      source: source,
      link: link
    } do
      expect_master([
        "RRULE:FREQ=WEEKLY;BYDAY=TU",
        "EXDATE;TZID=Europe/Tallinn:20261013T090000",
        "EXDATE;TZID=Europe/Tallinn:20261020T090000"
      ])

      expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
        {:ok, %{provider_event_id: "target-pid-1"}}
      end)

      assert :ok == Engine.mirror(link, weekly_instance(source), user.id)

      assert [] == CalendarSyncConflictQueries.list_for_link(link.id)
    end

    test "nor on a second pass whose exception set has grown", %{
      user: user,
      source: source,
      link: link
    } do
      expect_master([
        "RRULE:FREQ=WEEKLY;BYDAY=TU",
        "EXDATE;TZID=Europe/Tallinn:20261013T090000"
      ])

      expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
        {:ok, %{provider_event_id: "target-pid-1"}}
      end)

      assert :ok == Engine.mirror(link, weekly_instance(source), user.id)

      # The organiser cancels a second occurrence, and a later sweep sees it.
      # The master cache is cleared because the two passes are separate sweeps
      # rather than the same fan-out: within one sweep the cache is what stops a
      # master being fetched once per link, and between them its two-minute TTL
      # has long expired.
      SeriesMasterCache.clear_all()

      expect_master([
        "RRULE:FREQ=WEEKLY;BYDAY=TU",
        "EXDATE;TZID=Europe/Tallinn:20261013T090000",
        "EXDATE;TZID=Europe/Tallinn:20261020T090000"
      ])

      expect(Tymeslot.CalendarMock, :update_event, fn _uid, _data, _context -> :ok end)

      assert :ok == Engine.mirror(link, weekly_instance(source), user.id)

      assert [] == CalendarSyncConflictQueries.list_for_link(link.id)
    end

    test "a series with no exceptions records nothing, as before", %{
      user: user,
      source: source,
      link: link
    } do
      expect_master(["RRULE:FREQ=WEEKLY;BYDAY=TU"])

      expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
        {:ok, %{provider_event_id: "target-pid-1"}}
      end)

      assert :ok == Engine.mirror(link, weekly_instance(source), user.id)

      assert [] == CalendarSyncConflictQueries.list_for_link(link.id)
    end

    # The conflicts that describe a real, still-detectable divergence are
    # untouched by this. A failed write is still recorded, so silencing the
    # exception kind did not silence the log itself.
    test "a failed write is still recorded on the final attempt", %{
      user: user,
      source: source,
      link: link
    } do
      expect_master([
        "RRULE:FREQ=WEEKLY;BYDAY=TU",
        "EXDATE;TZID=Europe/Tallinn:20261013T090000"
      ])

      expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
        {:error, :rate_limited}
      end)

      assert {:error, :rate_limited} ==
               Engine.mirror(link, weekly_instance(source), user.id, attempt: 5)

      assert [conflict] = CalendarSyncConflictQueries.list_for_link(link.id)
      assert conflict.kind == "write_failed"
    end

    test "and a write still being retried records nothing", %{
      user: user,
      source: source,
      link: link
    } do
      expect_master([
        "RRULE:FREQ=WEEKLY;BYDAY=TU",
        "EXDATE;TZID=Europe/Tallinn:20261013T090000"
      ])

      expect(Tymeslot.CalendarMock, :create_event, fn _data, _context ->
        {:error, :rate_limited}
      end)

      assert {:error, :rate_limited} ==
               Engine.mirror(link, weekly_instance(source), user.id, attempt: 1)

      assert [] == CalendarSyncConflictQueries.list_for_link(link.id)
    end
  end
end
