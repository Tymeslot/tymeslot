defmodule Tymeslot.Integrations.Calendar.SyncCacheInvalidationTest do
  @moduledoc """
  Behavioural regression coverage for calendar sync invalidating the
  availability cache.

  After a provider sync persists new events the user's availability slots
  must be recomputed on the next lookup — returning cached pre-sync slots
  would mean a newly blocking event stays invisible to the booking page
  until the TTL expires.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :integrations
  @moduletag :calendar
  @moduletag :unit

  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.Sync

  setup do
    # DataCase already clears the cache, but be explicit — these tests
    # assert cache contents as the observable signal.
    AvailabilityCache.clear_all()
    :ok
  end

  defp build_timed_event(integration, opts) do
    now = DateTime.utc_now(:microsecond)

    CalendarEvent.new!(%{
      uid: Keyword.fetch!(opts, :uid),
      calendar_integration_id: integration.id,
      provider: :caldav,
      provider_calendar_id: "/cal/primary",
      provider_event_id:
        Keyword.get(opts, :provider_event_id, "evt-#{System.unique_integer([:positive])}"),
      all_day: false,
      start_at: now,
      end_at: DateTime.add(now, 3600, :second),
      synced_at: now
    })
  end

  describe "availability cache invalidation after sync" do
    test "persist_normalised_events invalidates cached slots for the integration owner" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      # Simulate a prior availability query for this user seeding the cache.
      # The cache entry represents the pre-sync "these slots are free" answer
      # that would be served to the booking page until invalidation or TTL.
      range_key =
        AvailabilityCache.availability_range_key(
          user.id,
          ~D[2026-06-01],
          ~D[2026-06-07],
          "Europe/London",
          30
        )

      month_key =
        AvailabilityCache.month_availability_key(user.id, 2026, 6, "Europe/London", 30)

      stale_range = {:stale, :range}
      stale_month = {:stale, :month}

      AvailabilityCache.put(range_key, stale_range)
      AvailabilityCache.put(month_key, stale_month)

      # Sanity: the cache really is populated with the stale response.
      assert AvailabilityCache.get_or_compute(range_key, fn -> :recomputed end) == stale_range
      assert AvailabilityCache.get_or_compute(month_key, fn -> :recomputed end) == stale_month

      # A provider sync persists a new blocking event for this user.
      event = build_timed_event(integration, uid: "cache-invalidation-evt-1")

      assert :ok = Sync.persist_normalised_events(integration, [event])

      # After sync, a subsequent availability lookup must NOT return the
      # stale pre-sync response — the compute lambda must fire and its
      # fresh result be served instead.
      assert AvailabilityCache.get_or_compute(range_key, fn -> :recomputed_range end) ==
               :recomputed_range

      assert AvailabilityCache.get_or_compute(month_key, fn -> :recomputed_month end) ==
               :recomputed_month
    end

    test "invalidation is scoped to the integration owner — other users' caches survive" do
      owner = insert(:user)
      other_user = insert(:user)
      integration = insert(:calendar_integration, user: owner)

      owner_key =
        AvailabilityCache.availability_range_key(
          owner.id,
          ~D[2026-07-01],
          ~D[2026-07-07],
          "Etc/UTC",
          60
        )

      other_key =
        AvailabilityCache.availability_range_key(
          other_user.id,
          ~D[2026-07-01],
          ~D[2026-07-07],
          "Etc/UTC",
          60
        )

      owner_stale = {:stale, :owner}
      other_value = {:live, :other}

      AvailabilityCache.put(owner_key, owner_stale)
      AvailabilityCache.put(other_key, other_value)

      event = build_timed_event(integration, uid: "cache-invalidation-evt-scope")

      assert :ok = Sync.persist_normalised_events(integration, [event])

      # Owner's cache was dropped — lambda fires and returns its value.
      assert AvailabilityCache.get_or_compute(owner_key, fn -> :recomputed end) == :recomputed

      # Unrelated user's cache is untouched — still returns the prior value
      # without invoking the compute fun.
      assert AvailabilityCache.get_or_compute(other_key, fn -> :should_not_run end) ==
               other_value
    end

    test "empty event list does not invalidate the cache" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      key =
        AvailabilityCache.availability_range_key(
          user.id,
          ~D[2026-08-01],
          ~D[2026-08-07],
          "Etc/UTC",
          30
        )

      value = {:live, :empty_sync}
      AvailabilityCache.put(key, value)

      assert :ok = Sync.persist_normalised_events(integration, [])

      # An empty sync batch is a no-op; the cache stays intact so we do not
      # needlessly hammer the availability compute path.
      assert AvailabilityCache.get_or_compute(key, fn -> :should_not_run end) == value
    end

    test "post_commit_reconciliation alone (transactional path) still invalidates the cache" do
      # CalDAV's atomic reconciler calls upsert_cache/2 and
      # post_commit_reconciliation/2 separately so the cache write participates
      # in a larger Repo.transaction. The cache invalidation must still fire.
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      key =
        AvailabilityCache.availability_range_key(
          user.id,
          ~D[2026-09-01],
          ~D[2026-09-07],
          "Etc/UTC",
          45
        )

      AvailabilityCache.put(key, {:stale, :transactional})

      event = build_timed_event(integration, uid: "cache-invalidation-evt-transactional")

      assert {:ok, _count} = Sync.upsert_cache(integration, [event])
      assert :ok = Sync.post_commit_reconciliation(integration, [event])

      assert AvailabilityCache.get_or_compute(key, fn -> :recomputed end) == :recomputed
    end

    test "deletion-only sync invalidates the cache via invalidate_cache_for_user/1" do
      # Regression: a sync that only deletes events (empty calendar_events list)
      # must still invalidate the availability cache.
      # `post_commit_reconciliation/2` short-circuits on an empty list, so the
      # atomic CalDAV paths call `invalidate_cache_for_user/1` separately when
      # deletions occurred. This test validates that helper clears stale entries.
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      key =
        AvailabilityCache.availability_range_key(
          user.id,
          ~D[2026-10-01],
          ~D[2026-10-07],
          "Etc/UTC",
          30
        )

      AvailabilityCache.put(key, {:stale, :deletion_only})

      assert :ok = Sync.invalidate_cache_for_user(integration)

      assert AvailabilityCache.get_or_compute(key, fn -> :recomputed end) == :recomputed
    end

    test "invalidate_cache_for_user/1 returns :ok even when the ETS table is absent" do
      # Regression: if AvailabilityCache is mid-restart its ETS table is gone
      # and :ets.match_delete raises ArgumentError. A committed sync transaction
      # must not propagate that crash — the function must return :ok regardless.
      #
      # We simulate the mid-restart window by deleting the ETS table directly.
      # The table is :public so any process can drop it. We restore state by
      # re-creating the table and handing ownership to the AvailabilityCache
      # GenServer — if ownership stays with the test process, the table would
      # be dropped when this process exits, poisoning subsequent tests.
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      cache_pid = Process.whereis(AvailabilityCache)
      :ets.delete(:availability_cache)

      try do
        assert :ok = Sync.invalidate_cache_for_user(integration)
      after
        new_table =
          :ets.new(:availability_cache, [:named_table, :public, :set, read_concurrency: true])

        :ets.give_away(new_table, cache_pid, :restored)
      end
    end
  end
end
