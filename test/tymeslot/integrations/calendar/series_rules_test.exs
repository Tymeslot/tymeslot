defmodule Tymeslot.Integrations.Calendar.SeriesRulesTest do
  @moduledoc """
  The stored rules of Google and Outlook series, as the cache writes see
  them: copied onto each occurrence an upsert caches, and forgotten once the
  cache holds no occurrence of their series.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :integrations

  import ExUnit.CaptureLog

  alias Ecto.Changeset
  alias Tymeslot.CalendarGrid.EventDeletion
  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.Google.CacheSweep
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Integrations.Calendar.SeriesRuleQueries
  alias Tymeslot.Integrations.Calendar.SeriesRules
  alias Tymeslot.Integrations.Calendar.Sync
  alias Tymeslot.Repo
  alias Tymeslot.Workers.CalendarCachePruneWorker

  setup do
    %{integration: insert(:calendar_integration, provider: "outlook")}
  end

  describe "an upsert of occurrences" do
    test "gives each occurrence its series' stored rule", %{integration: integration} do
      put_rule(integration, "master-1", "FREQ=WEEKLY;BYDAY=MO")

      assert {:ok, 2} =
               Sync.upsert_cache(integration, [
                 occurrence(integration, "occ-1", "master-1"),
                 occurrence(integration, "occ-2", nil)
               ])

      assert rule_of(integration, "occ-1") == "FREQ=WEEKLY;BYDAY=MO"
      assert rule_of(integration, "occ-2") == nil
    end

    test "leaves an occurrence of a series with no stored rule without one", %{
      integration: integration
    } do
      assert {:ok, 1} =
               Sync.upsert_cache(integration, [occurrence(integration, "occ-1", "master-1")])

      assert rule_of(integration, "occ-1") == nil
    end

    # The upsert replaces a row's rule with what the event carries, and the
    # provider's events carry none.
    test "keeps the rule when the occurrence is cached again", %{integration: integration} do
      put_rule(integration, "master-1", "FREQ=WEEKLY;BYDAY=MO")
      event = occurrence(integration, "occ-1", "master-1")

      {:ok, 1} = Sync.upsert_cache(integration, [event])
      {:ok, 1} = Sync.upsert_cache(integration, [%{event | summary: "Renamed"}])

      assert rule_of(integration, "occ-1") == "FREQ=WEEKLY;BYDAY=MO"
    end

    test "keeps a rule the event carries of its own", %{integration: integration} do
      put_rule(integration, "master-1", "FREQ=WEEKLY;BYDAY=MO")

      event = %{occurrence(integration, "occ-1", "master-1") | recurrence_rule: "FREQ=DAILY"}
      {:ok, 1} = Sync.upsert_cache(integration, [event])

      assert rule_of(integration, "occ-1") == "FREQ=DAILY"
    end

    test "reads another integration's rule for nothing", %{integration: integration} do
      other = insert(:calendar_integration, provider: "outlook")
      put_rule(other, "master-1", "FREQ=WEEKLY;BYDAY=MO")

      {:ok, 1} = Sync.upsert_cache(integration, [occurrence(integration, "occ-1", "master-1")])

      assert rule_of(integration, "occ-1") == nil
    end
  end

  describe "a deletion of occurrences" do
    test "forgets the rule of a series with none left, and keeps the others", %{
      integration: integration
    } do
      put_rule(integration, "master-1", "FREQ=WEEKLY;BYDAY=MO")
      put_rule(integration, "master-2", "FREQ=DAILY")

      {:ok, 2} =
        Sync.upsert_cache(integration, [
          occurrence(integration, "occ-1", "master-1"),
          occurrence(integration, "occ-2", "master-2")
        ])

      :ok = Sync.reconcile_deletions(integration, [%{provider_event_id: "occ-1", uid: "occ-1"}])

      assert stored_rule(integration, "master-1") == nil
      assert %{rule: "FREQ=DAILY"} = stored_rule(integration, "master-2")
    end
  end

  describe "every path that deletes occurrences" do
    setup %{integration: integration} do
      put_rule(integration, "gone-master", "FREQ=DAILY")
      put_rule(integration, "kept-master", "FREQ=WEEKLY")

      {:ok, 2} =
        Sync.upsert_cache(integration, [
          occurrence(integration, "gone-occ", "gone-master"),
          occurrence(integration, "kept-occ", "kept-master")
        ])

      :ok
    end

    test "a Google sweep of a listing forgets the rules of the series it emptied", %{
      integration: integration
    } do
      # The listing returned the kept series again; the other is gone from it.
      Repo.update_all(ProviderCalendarEventSchema,
        set: [updated_at: ~U[2026-01-01 00:00:00.000000Z]]
      )

      {:ok, kept} = ProviderCalendarEventQueries.get_by_uid(integration.id, "kept-occ")
      Repo.update!(Changeset.change(kept, updated_at: DateTime.utc_now()))

      :ok =
        CacheSweep.sweep(
          integration,
          [{"calendar-1", {~U[2026-10-01 00:00:00Z], ~U[2026-11-30 00:00:00Z]}}],
          DateTime.add(DateTime.utc_now(:second), -60, :second)
        )

      assert stored_rule(integration, "gone-master") == nil
      assert stored_rule(integration, "kept-master")
    end

    test "the cache prune forgets the rules of the series it emptied", %{
      integration: integration
    } do
      ProviderCalendarEventQueries.delete_by_uids(integration.id, ["gone-occ"])

      assert :ok = CalendarCachePruneWorker.perform(%Oban.Job{})

      assert stored_rule(integration, "gone-master") == nil
      assert stored_rule(integration, "kept-master")
    end

    test "deleting a whole series' rows from the grid forgets its rule", %{
      integration: integration
    } do
      :ok = EventDeletion.delete_series_rows(integration.id, {:master, "gone-master"})

      assert stored_rule(integration, "gone-master") == nil
      assert stored_rule(integration, "kept-master")
    end
  end

  describe "refresh/3" do
    test "reads the masters the events name and stores what it found", %{
      integration: integration
    } do
      read = reader(%{"master-1" => {:ok, found("FREQ=WEEKLY;BYDAY=MO")}})

      assert :ok =
               SeriesRules.refresh(
                 integration.id,
                 [occurrence(integration, "occ-1", "master-1")],
                 read
               )

      assert_received {:read, "master-1"}

      assert %{rule: "FREQ=WEEKLY;BYDAY=MO", master_start: ~U[2026-10-05 07:00:00Z]} =
               stored_rule(integration, "master-1")
    end

    test "reads a master a change names again however fresh its rule is", %{
      integration: integration
    } do
      put_rule(integration, "master-1", "FREQ=DAILY")
      read = reader(%{"master-1" => {:ok, found("FREQ=WEEKLY;BYDAY=MO")}})
      events = [occurrence(integration, "occ-1", "master-1")]

      SeriesRules.refresh(integration.id, events, read, changed: true)

      assert stored_rule(integration, "master-1").rule == "FREQ=WEEKLY;BYDAY=MO"
    end

    # A listing says nothing changed: a sync run that lists a calendar every
    # time must not read every series it holds every time.
    test "reads no master a listing names while its rule is fresh", %{integration: integration} do
      put_rule(integration, "master-1", "FREQ=DAILY")
      read = reader(%{"master-1" => {:ok, found("FREQ=WEEKLY;BYDAY=MO")}})

      SeriesRules.refresh(integration.id, [occurrence(integration, "occ-1", "master-1")], read)

      assert received_reads() == []
    end

    # A sync cycle calls refresh once per batch it caches: the delta, the
    # series it relists, each other calendar.
    test "reads at most 50 masters across the calls of one cycle", %{integration: integration} do
      batch = fn range ->
        for n <- range, do: occurrence(integration, "occ-#{n}", "master-#{n}")
      end

      read = reader(Map.new(1..60, &{"master-#{&1}", {:ok, found("FREQ=DAILY")}}))

      SeriesRules.refresh(integration.id, batch.(1..30), read, changed: true)
      SeriesRules.refresh(integration.id, batch.(31..60), read, changed: true)

      assert length(received_reads()) == 50
    end

    # A series the cache already holds, whose occurrences did not change.
    test "reads a cached series' master once its rule is stale, and not before", %{
      integration: integration
    } do
      {:ok, 2} =
        Sync.upsert_cache(integration, [
          occurrence(integration, "occ-1", "stale-master"),
          occurrence(integration, "occ-2", "fresh-master")
        ])

      put_rule(integration, "fresh-master", "FREQ=DAILY")

      put_rule(
        integration,
        "stale-master",
        "FREQ=DAILY",
        DateTime.add(DateTime.utc_now(:second), -2, :day)
      )

      read =
        reader(%{
          "stale-master" => {:ok, found("FREQ=WEEKLY")},
          "fresh-master" => {:ok, found("FREQ=WEEKLY")}
        })

      SeriesRules.refresh(integration.id, [], read)

      assert_received {:read, "stale-master"}
      refute_received {:read, "fresh-master"}

      # The occurrence the provider did not send again gets the rule read.
      assert rule_of(integration, "occ-1") == "FREQ=WEEKLY"
    end

    # A busy calendar's bootstrap names more series than one run reads, and a
    # throttled run stops early: their occurrences are cached without a rule.
    test "gives an occurrence cached while its rule was unread that rule, once read", %{
      integration: integration
    } do
      {:ok, 1} = Sync.upsert_cache(integration, [occurrence(integration, "occ-1", "master-1")])
      assert rule_of(integration, "occ-1") == nil

      SeriesRules.refresh(integration.id, [], reader(%{"master-1" => {:ok, found("FREQ=DAILY")}}))

      assert rule_of(integration, "occ-1") == "FREQ=DAILY"
    end

    test "gives a changed rule to the occurrences a change did not send again", %{
      integration: integration
    } do
      put_rule(integration, "master-1", "FREQ=DAILY")

      {:ok, 2} =
        Sync.upsert_cache(integration, [
          occurrence(integration, "occ-1", "master-1"),
          occurrence(integration, "occ-2", "master-1")
        ])

      read = reader(%{"master-1" => {:ok, found("FREQ=WEEKLY;BYDAY=MO")}})
      events = [occurrence(integration, "occ-1", "master-1")]

      SeriesRules.refresh(integration.id, events, read, changed: true)

      assert rule_of(integration, "occ-2") == "FREQ=WEEKLY;BYDAY=MO"
    end

    test "takes the rule off the occurrences of a master found gone", %{integration: integration} do
      put_rule(integration, "master-1", "FREQ=DAILY")
      {:ok, 1} = Sync.upsert_cache(integration, [occurrence(integration, "occ-1", "master-1")])

      SeriesRules.refresh(
        integration.id,
        [occurrence(integration, "occ-1", "master-1")],
        reader(%{"master-1" => :gone}),
        changed: true
      )

      assert rule_of(integration, "occ-1") == nil
    end

    test "reads at most 50 masters a run", %{integration: integration} do
      events = for n <- 1..60, do: occurrence(integration, "occ-#{n}", "master-#{n}")
      read = reader(Map.new(1..60, &{"master-#{&1}", {:ok, found("FREQ=DAILY")}}))

      SeriesRules.refresh(integration.id, events, read)

      assert length(received_reads()) == 50
    end

    test "records a master that is gone, so that it is not asked about again at once", %{
      integration: integration
    } do
      read = reader(%{"master-1" => :gone})

      SeriesRules.refresh(integration.id, [occurrence(integration, "occ-1", "master-1")], read)
      assert_received {:read, "master-1"}
      {:ok, 1} = Sync.upsert_cache(integration, [occurrence(integration, "occ-1", "master-1")])

      assert %{rule: nil} = stored_rule(integration, "master-1")
      assert rule_of(integration, "occ-1") == nil

      SeriesRules.refresh(integration.id, [], read)
      refute_received {:read, "master-1"}
    end

    # Graph and Google ids run past 255 bytes.
    test "stores the rule of a master whose id is longer than 255 bytes", %{
      integration: integration
    } do
      master_id = String.duplicate("A", 300)
      read = reader(%{master_id => {:ok, found("FREQ=DAILY")}})

      SeriesRules.refresh(integration.id, [occurrence(integration, "occ-1", master_id)], read)

      assert stored_rule(integration, master_id).rule == "FREQ=DAILY"
    end

    test "skips a read it cannot store and goes on to the next", %{integration: integration} do
      read =
        reader(%{
          "master-1" => {:ok, %{rule: 123, master_start: nil}},
          "master-2" => {:ok, found("FREQ=DAILY")}
        })

      events = [
        occurrence(integration, "occ-1", "master-1"),
        occurrence(integration, "occ-2", "master-2")
      ]

      log = capture_log(fn -> assert :ok = SeriesRules.refresh(integration.id, events, read) end)

      assert log =~ "could not be stored"
      assert stored_rule(integration, "master-1") == nil
      assert stored_rule(integration, "master-2").rule == "FREQ=DAILY"
    end

    # Failed reads spend the budget as stored ones do: a run of reads whose
    # results cannot be stored makes no more GETs than a run that succeeds.
    test "reads at most 50 masters even when no read can be stored", %{integration: integration} do
      batch = fn range ->
        for n <- range, do: occurrence(integration, "occ-#{n}", "master-#{n}")
      end

      read = reader(Map.new(1..60, &{"master-#{&1}", {:ok, %{rule: 123, master_start: nil}}}))

      capture_log(fn ->
        SeriesRules.refresh(integration.id, batch.(1..30), read, changed: true)
        SeriesRules.refresh(integration.id, batch.(31..60), read, changed: true)
      end)

      assert length(received_reads()) == 50
    end

    # A throttled read stops its call, but a cycle makes many calls.
    test "reads at most 50 masters across calls each stopped by its first read", %{
      integration: integration
    } do
      read = reader(Map.new(1..60, &{"master-#{&1}", {:stop, :rate_limited}}))

      capture_log(fn ->
        for n <- 1..60 do
          event = occurrence(integration, "occ-#{n}", "master-#{n}")
          SeriesRules.refresh(integration.id, [event], read, changed: true)
        end
      end)

      assert length(received_reads()) == 50
    end

    # Throttled, refused or unreachable: every later read would fail alike.
    test "stops reading at the first read that says to stop", %{integration: integration} do
      read =
        reader(%{
          "master-1" => {:stop, :rate_limited},
          "master-2" => {:ok, found("FREQ=DAILY")}
        })

      events = [
        occurrence(integration, "occ-1", "master-1"),
        occurrence(integration, "occ-2", "master-2")
      ]

      assert :ok = SeriesRules.refresh(integration.id, events, read)

      assert received_reads() == ["master-1"]
      assert stored_rule(integration, "master-2") == nil
    end
  end

  describe "with_series_start/1" do
    test "gives an occurrence its series' first start, and nothing else", %{
      integration: integration
    } do
      put_rule(integration, "master-1", "FREQ=WEEKLY;COUNT=5")

      [stamped, single, unknown] =
        SeriesRules.with_series_start([
          %{calendar_integration_id: integration.id, recurring_event_id: "master-1"},
          %{calendar_integration_id: integration.id, recurring_event_id: nil},
          %{calendar_integration_id: nil, recurring_event_id: "master-1"}
        ])

      assert stamped.series_start == ~U[2026-10-05 07:00:00Z]
      refute Map.has_key?(single, :series_start)
      refute Map.has_key?(unknown, :series_start)
    end
  end

  defp put_rule(integration, master_id, rule, fetched_at \\ DateTime.utc_now(:second)) do
    {:ok, _row} =
      SeriesRuleQueries.put(integration.id, master_id, %{
        rule: rule,
        master_start: ~U[2026-10-05 07:00:00Z],
        fetched_at: fetched_at
      })
  end

  defp found(rule), do: %{rule: rule, master_start: ~U[2026-10-05 07:00:00Z]}

  # Answers each master as `answers` says, and reports each read.
  defp reader(answers) do
    test_pid = self()

    fn master_id, _calendar_id ->
      send(test_pid, {:read, master_id})
      Map.fetch!(answers, master_id)
    end
  end

  defp received_reads do
    receive do
      {:read, master_id} -> [master_id | received_reads()]
    after
      0 -> []
    end
  end

  defp occurrence(integration, id, master_id) do
    CalendarEvent.new!(%{
      uid: id,
      calendar_integration_id: integration.id,
      provider: :outlook,
      provider_calendar_id: "calendar-1",
      provider_event_id: id,
      recurring_event_id: master_id,
      summary: "Weekly standup",
      all_day: false,
      start_at: ~U[2026-10-19 07:00:00Z],
      end_at: ~U[2026-10-19 07:30:00Z],
      synced_at: DateTime.utc_now()
    })
  end

  defp rule_of(integration, uid) do
    {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, uid)
    row.recurrence_rule
  end

  # The series' stored row, or nil.
  defp stored_rule(integration, master_id),
    do: Map.get(SeriesRuleQueries.list_by_master(integration.id, [master_id]), master_id)
end
