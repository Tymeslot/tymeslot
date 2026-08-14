defmodule Tymeslot.Integrations.Calendar.SyncLink.MovedOccurrenceTest do
  @moduledoc """
  A single occurrence dragged to a different time, seen from the one place it
  is still visible.

  `Sync.post_commit_reconciliation/2` receives the *uncollapsed* list of
  normalised events — the dedup that reduces a series to one cache row happens
  later, inside `upsert_batch/1`. So the moved instance and its unmoved siblings
  are all in hand here, each carrying the `original_start_at` the normaliser
  captured, and the divergence can be read off them without a single extra
  provider request.

  That last part is asserted by omission: no Mox expectation is set on any
  provider, so `verify_on_exit!` fails the test if detection reaches one. The
  cost of correcting a move was what got it deferred, and a detection pass that
  quietly reintroduced a per-series request would defeat the point of measuring
  first.

  Nothing here asserts that the placeholder is fixed, because it is not. The
  block still sits at the occurrence's original time and no block sits at its
  new one.
  """
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :sync_links

  import Mox
  import Tymeslot.Factory
  import Tymeslot.SyncLinkTestHelpers

  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.CalendarSyncConflictQueries
  alias Tymeslot.Integrations.Calendar.CalendarSyncConflictSchema
  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkQueries
  alias Tymeslot.Integrations.Calendar.Sync
  alias Tymeslot.Repo

  setup :verify_on_exit!

  setup do
    linked_pair()
  end

  @series_uid "weekly@google.com"

  # One expanded instance of a weekly series. `original_start_at` left nil is an
  # ordinary occurrence; set, it is one Google reports as moved.
  defp occurrence(integration, start_at, opts \\ []) do
    CalendarEvent.new!(%{
      uid: Keyword.get(opts, :uid, @series_uid),
      calendar_integration_id: integration.id,
      provider: :google,
      provider_calendar_id: "primary",
      provider_event_id: "master_abc_" <> DateTime.to_iso8601(start_at),
      recurring_event_id: Keyword.get(opts, :recurring_event_id, "master_abc"),
      summary: "Weekly standup",
      all_day: false,
      start_at: start_at,
      end_at: DateTime.add(start_at, 30, :minute),
      recurrence_rule: "RRULE:FREQ=WEEKLY;BYDAY=TU",
      original_start_at: Keyword.get(opts, :original_start_at),
      synced_at: ~U[2026-12-01 00:00:00Z]
    })
  end

  defp conflicts(link), do: CalendarSyncConflictQueries.list_for_link(link.id)

  defp moved_rows(link), do: Enum.filter(conflicts(link), &(&1.kind == "occurrence_moved"))

  describe "a moved occurrence in a mirrored series" do
    test "logs exactly one row naming the count and the original-vs-new times", %{
      source: source,
      link: link
    } do
      events = [
        occurrence(source, ~U[2026-12-08 09:00:00Z]),
        occurrence(source, ~U[2026-12-15 14:00:00Z], original_start_at: ~U[2026-12-15 09:00:00Z]),
        occurrence(source, ~U[2026-12-22 09:00:00Z])
      ]

      :ok = Sync.post_commit_reconciliation(source, events)

      assert [row] = moved_rows(link)
      assert row.source_uid == @series_uid
      assert row.resolution == "skipped"
      assert row.detail["moved_count"] == 1
      assert row.detail["recurring_event_id"] == "master_abc"

      assert [%{"original_start" => original, "new_start" => new}] = row.detail["occurrences"]
      assert original == "2026-12-15T09:00:00Z"
      assert new == "2026-12-15T14:00:00Z"
    end

    test "three moves in one series are one row, not three", %{source: source, link: link} do
      events = [
        occurrence(source, ~U[2026-12-08 11:00:00Z], original_start_at: ~U[2026-12-08 09:00:00Z]),
        occurrence(source, ~U[2026-12-15 14:00:00Z], original_start_at: ~U[2026-12-15 09:00:00Z]),
        occurrence(source, ~U[2026-12-22 08:00:00Z], original_start_at: ~U[2026-12-22 09:00:00Z]),
        occurrence(source, ~U[2026-12-29 09:00:00Z])
      ]

      :ok = Sync.post_commit_reconciliation(source, events)

      assert [row] = moved_rows(link)
      assert row.detail["moved_count"] == 3
      assert length(row.detail["occurrences"]) == 3

      # Ordered by where the occurrence used to be, so two renderings of the
      # same set read the same way and the dedup below compares like with like.
      assert Enum.map(row.detail["occurrences"], & &1["original_start"]) == [
               "2026-12-08T09:00:00Z",
               "2026-12-15T09:00:00Z",
               "2026-12-22T09:00:00Z"
             ]
    end

    test "two series each moved get a row apiece", %{source: source, link: link} do
      events = [
        occurrence(source, ~U[2026-12-15 14:00:00Z], original_start_at: ~U[2026-12-15 09:00:00Z]),
        occurrence(source, ~U[2026-12-16 16:00:00Z],
          uid: "monthly@google.com",
          recurring_event_id: "master_xyz",
          original_start_at: ~U[2026-12-16 10:00:00Z]
        )
      ]

      :ok = Sync.post_commit_reconciliation(source, events)

      assert MapSet.new(moved_rows(link), & &1.source_uid) ==
               MapSet.new([@series_uid, "monthly@google.com"])
    end

    test "an all-day occurrence moved to another day is reported by date", %{
      source: source,
      link: link
    } do
      moved =
        CalendarEvent.new!(%{
          uid: @series_uid,
          calendar_integration_id: source.id,
          provider: :google,
          provider_calendar_id: "primary",
          provider_event_id: "master_abc_20261215",
          recurring_event_id: "master_abc",
          summary: "Weekly review",
          all_day: true,
          start_date: ~D[2026-12-16],
          end_date: ~D[2026-12-17],
          original_start_at: ~D[2026-12-15],
          recurrence_rule: "RRULE:FREQ=WEEKLY",
          synced_at: ~U[2026-12-01 00:00:00Z]
        })

      :ok = Sync.post_commit_reconciliation(source, [moved])

      assert [row] = moved_rows(link)

      assert [%{"original_start" => "2026-12-15", "new_start" => "2026-12-16"}] =
               row.detail["occurrences"]
    end
  end

  describe "what is not a move" do
    test "an unchanged set of moves does not append a row on the next sync", %{
      source: source,
      link: link
    } do
      events = [
        occurrence(source, ~U[2026-12-15 14:00:00Z], original_start_at: ~U[2026-12-15 09:00:00Z]),
        occurrence(source, ~U[2026-12-22 09:00:00Z])
      ]

      :ok = Sync.post_commit_reconciliation(source, events)
      assert [first] = moved_rows(link)

      :ok = Sync.post_commit_reconciliation(source, events)
      assert [^first] = moved_rows(link)
    end

    test "a further move on the same series does append a row", %{source: source, link: link} do
      first_pass = [
        occurrence(source, ~U[2026-12-15 14:00:00Z], original_start_at: ~U[2026-12-15 09:00:00Z])
      ]

      :ok = Sync.post_commit_reconciliation(source, first_pass)
      assert [_one] = moved_rows(link)

      second_pass =
        first_pass ++
          [
            occurrence(source, ~U[2026-12-22 08:00:00Z],
              original_start_at: ~U[2026-12-22 09:00:00Z]
            )
          ]

      :ok = Sync.post_commit_reconciliation(source, second_pass)

      assert [latest, _earlier] = moved_rows(link)
      assert latest.detail["moved_count"] == 2
    end

    test "an occurrence whose original start equals its actual start is not moved", %{
      source: source,
      link: link
    } do
      events = [
        occurrence(source, ~U[2026-12-15 09:00:00Z], original_start_at: ~U[2026-12-15 09:00:00Z])
      ]

      :ok = Sync.post_commit_reconciliation(source, events)

      assert [] == moved_rows(link)
    end

    test "an ordinary series with no moves logs nothing", %{source: source, link: link} do
      events = [
        occurrence(source, ~U[2026-12-08 09:00:00Z]),
        occurrence(source, ~U[2026-12-15 09:00:00Z])
      ]

      :ok = Sync.post_commit_reconciliation(source, events)

      assert [] == conflicts(link)
    end
  end

  describe "only a mirrored series is reported" do
    test "a move on a calendar no link mirrors logs nothing", %{user: user} do
      unlinked = insert(:calendar_integration, user: user, provider: "google")

      events = [
        occurrence(unlinked, ~U[2026-12-15 14:00:00Z],
          original_start_at: ~U[2026-12-15 09:00:00Z]
        )
      ]

      :ok = Sync.post_commit_reconciliation(unlinked, events)

      # No link exists to scope a read by, so the assertion is on the whole
      # table: nothing anywhere was written for a calendar nobody mirrors.
      assert [] == Repo.all(CalendarSyncConflictSchema)
    end

    test "a move is not reported to a target that cannot hold a series", %{
      user: user,
      source: source,
      link: google_link
    } do
      # Outlook has no `:recurrence` capability, so `Eligibility` refuses the
      # recurring source before the engine is reached and this link never
      # received a placeholder for the series at all. A row saying its
      # placeholder sits at the wrong time describes something that was never
      # written — and the whole point of this log is counting how often moves
      # matter, which links that mirror no series would inflate.
      outlook_target = insert(:calendar_integration, user: user, provider: "outlook")

      outlook_link =
        insert(:calendar_sync_link,
          user_id: user.id,
          source_integration_id: source.id,
          target_integration_id: outlook_target.id
        )

      events = [
        occurrence(source, ~U[2026-12-15 14:00:00Z], original_start_at: ~U[2026-12-15 09:00:00Z])
      ]

      :ok = Sync.post_commit_reconciliation(source, events)

      assert [] == moved_rows(outlook_link)
      assert [_reported] = moved_rows(google_link)
    end

    test "a move on a source whose only link is disabled logs nothing", %{
      source: source,
      link: link
    } do
      {:ok, _updated} = CalendarSyncLinkQueries.update(link, %{enabled: false})

      events = [
        occurrence(source, ~U[2026-12-15 14:00:00Z], original_start_at: ~U[2026-12-15 09:00:00Z])
      ]

      :ok = Sync.post_commit_reconciliation(source, events)

      assert [] == moved_rows(link)
    end

    test "each link out of the source gets its own row", %{source: source, link: link} = ctx do
      {_second_target, second_link} = extra_target_link(ctx)

      events = [
        occurrence(source, ~U[2026-12-15 14:00:00Z], original_start_at: ~U[2026-12-15 09:00:00Z])
      ]

      :ok = Sync.post_commit_reconciliation(source, events)

      assert [_first] = moved_rows(link)
      assert [_second] = moved_rows(second_link)
    end
  end
end
