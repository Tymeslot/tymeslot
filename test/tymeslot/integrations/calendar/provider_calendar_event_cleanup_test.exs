defmodule Tymeslot.Integrations.Calendar.ProviderCalendarEventCleanupTest do
  @moduledoc """
  Drives `20260415192059_cleanup_calendar_event_duplicates_and_add_status_constraints`,
  which:

  - Remaps `status='free'` rows to `(status='confirmed', transparency='transparent')`
  - De-duplicates `(calendar_integration_id, summary, start_at, end_at)` clusters
  - Enforces CHECK constraints on `status` and `transparency`

  Runs non-async because it temporarily drops the CHECK constraints to
  simulate the pre-migration database state and insert adversarial rows; the
  migration puts them back, so the constraint tests exercise the constraints
  the migration installs rather than hand-written copies of them.

  The migration module is loaded from `priv` and run through `Ecto.Migrator`;
  see `Tymeslot.Test.MigrationRunner`.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :calendar

  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_260_415_192_059

  setup do
    # Drop the CHECK constraints so we can insert adversarial rows that
    # the migration is supposed to clean up. The sandbox rolls the DDL back
    # with the test, and the migration re-adds them on its way through.
    Repo.query!(
      "ALTER TABLE provider_calendar_events DROP CONSTRAINT IF EXISTS provider_calendar_events_status_check"
    )

    Repo.query!(
      "ALTER TABLE provider_calendar_events DROP CONSTRAINT IF EXISTS provider_calendar_events_transparency_check"
    )

    integration = insert(:calendar_integration)

    {:ok, integration: integration}
  end

  describe "status='free' normalisation" do
    test "remaps status='free' to status='confirmed' + transparency='transparent'",
         %{integration: integration} do
      {:ok, _result} =
        Repo.query(
          """
          INSERT INTO provider_calendar_events
            (calendar_integration_id, provider, provider_calendar_id, uid,
             summary, start_at, end_at, status, transparency, all_day,
             synced_at, inserted_at, updated_at)
          VALUES ($1, 'caldav', 'cal-1', 'free-uid-1',
                  'Free event', now(), now() + interval '1 hour',
                  'free', 'opaque', false, now(), now(), now())
          """,
          [integration.id]
        )

      run_migration!()

      row = Repo.get_by(ProviderCalendarEventSchema, uid: "free-uid-1")
      assert row.status == "confirmed"
      assert row.transparency == "transparent"
    end
  end

  describe "duplicate cluster removal" do
    test "keeps the newest synced_at row and deletes the older duplicates",
         %{integration: integration} do
      start_at = ~U[2026-05-01 10:00:00Z]
      end_at = ~U[2026-05-01 11:00:00Z]

      insert_raw_timed(integration, %{
        uid: "dup-uid-old",
        summary: "Dup event",
        start_at: start_at,
        end_at: end_at,
        synced_at: ~U[2026-04-01 09:00:00Z]
      })

      insert_raw_timed(integration, %{
        uid: "dup-uid-newest",
        summary: "Dup event",
        start_at: start_at,
        end_at: end_at,
        synced_at: ~U[2026-04-10 09:00:00Z]
      })

      insert_raw_timed(integration, %{
        uid: "dup-uid-middle",
        summary: "Dup event",
        start_at: start_at,
        end_at: end_at,
        synced_at: ~U[2026-04-05 09:00:00Z]
      })

      run_migration!()

      # Only the newest survivor remains.
      assert surviving_uids(integration, "Dup event") == ["dup-uid-newest"]
    end

    test "de-duplicates all-day clusters by (summary, start_date, end_date)",
         %{integration: integration} do
      insert_raw_all_day(integration, %{
        uid: "allday-old",
        summary: "Holiday",
        start_date: ~D[2026-05-01],
        end_date: ~D[2026-05-03],
        synced_at: ~U[2026-04-01 09:00:00Z]
      })

      insert_raw_all_day(integration, %{
        uid: "allday-new",
        summary: "Holiday",
        start_date: ~D[2026-05-01],
        end_date: ~D[2026-05-03],
        synced_at: ~U[2026-04-10 09:00:00Z]
      })

      run_migration!()

      assert surviving_uids(integration, "Holiday") == ["allday-new"]
    end

    test "preserves all-day rows with NULL end_date — cannot safely merge them",
         %{integration: integration} do
      # Two rows share (integration, summary, start_date) but both have NULL
      # end_date. Before the fix the PARTITION BY grouped them together and
      # deleted one. After the fix both must survive.
      Repo.query!(
        """
        INSERT INTO provider_calendar_events
          (calendar_integration_id, provider, provider_calendar_id, uid,
           summary, start_date, end_date, status, transparency, all_day,
           synced_at, inserted_at, updated_at)
        VALUES ($1, 'caldav', 'cal-1', 'null-end-a',
                'No End Event', '2026-06-01', NULL,
                'confirmed', 'opaque', true, now(), now(), now()),
               ($1, 'caldav', 'cal-1', 'null-end-b',
                'No End Event', '2026-06-01', NULL,
                'confirmed', 'opaque', true, now(), now(), now())
        """,
        [integration.id]
      )

      run_migration!()

      assert Repo.get_by(ProviderCalendarEventSchema, uid: "null-end-a")
      assert Repo.get_by(ProviderCalendarEventSchema, uid: "null-end-b")
    end

    test "leaves non-duplicate rows untouched", %{integration: integration} do
      insert_raw_timed(integration, %{
        uid: "unique-a",
        summary: "Event A",
        start_at: ~U[2026-05-01 10:00:00Z],
        end_at: ~U[2026-05-01 11:00:00Z],
        synced_at: ~U[2026-04-10 09:00:00Z]
      })

      insert_raw_timed(integration, %{
        uid: "unique-b",
        summary: "Event B",
        start_at: ~U[2026-05-01 10:00:00Z],
        end_at: ~U[2026-05-01 11:00:00Z],
        synced_at: ~U[2026-04-10 09:00:00Z]
      })

      run_migration!()

      assert Repo.get_by(ProviderCalendarEventSchema, uid: "unique-a")
      assert Repo.get_by(ProviderCalendarEventSchema, uid: "unique-b")
    end

    test "leaves rows with nil summary alone (can't safely merge)",
         %{integration: integration} do
      insert_raw_timed(integration, %{
        uid: "null-summary-a",
        summary: nil,
        start_at: ~U[2026-05-01 10:00:00Z],
        end_at: ~U[2026-05-01 11:00:00Z],
        synced_at: ~U[2026-04-01 09:00:00Z]
      })

      insert_raw_timed(integration, %{
        uid: "null-summary-b",
        summary: nil,
        start_at: ~U[2026-05-01 10:00:00Z],
        end_at: ~U[2026-05-01 11:00:00Z],
        synced_at: ~U[2026-04-10 09:00:00Z]
      })

      run_migration!()

      assert Repo.get_by(ProviderCalendarEventSchema, uid: "null-summary-a")
      assert Repo.get_by(ProviderCalendarEventSchema, uid: "null-summary-b")
    end
  end

  describe "CHECK constraints" do
    test "reject invalid status values once installed", %{integration: integration} do
      run_migration!()

      assert_raise Postgrex.Error, ~r/status_check/, fn ->
        Repo.query!(
          """
          INSERT INTO provider_calendar_events
            (calendar_integration_id, provider, provider_calendar_id, uid,
             summary, start_at, end_at, status, transparency, all_day,
             synced_at, inserted_at, updated_at)
          VALUES ($1, 'caldav', 'cal-1', 'bad-status-uid',
                  'Bad status', now(), now() + interval '1 hour',
                  'bogus', 'opaque', false, now(), now(), now())
          """,
          [integration.id]
        )
      end
    end

    test "reject invalid transparency values once installed", %{integration: integration} do
      run_migration!()

      assert_raise Postgrex.Error, ~r/transparency_check/, fn ->
        Repo.query!(
          """
          INSERT INTO provider_calendar_events
            (calendar_integration_id, provider, provider_calendar_id, uid,
             summary, start_at, end_at, status, transparency, all_day,
             synced_at, inserted_at, updated_at)
          VALUES ($1, 'caldav', 'cal-1', 'bad-transparency-uid',
                  'Bad transparency', now(), now() + interval '1 hour',
                  'confirmed', 'semi-transparent', false, now(), now(), now())
          """,
          [integration.id]
        )
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers

  # Every step of `up/0` is idempotent (NULL-guarded UPDATE, rank-based DELETE,
  # `DROP CONSTRAINT IF EXISTS` before each `ADD`), so the version is dropped
  # from the ledger and the migration re-applied over the migrated schema.
  # `down/0` only removes the constraints; it cannot restore the deleted rows.
  defp run_migration! do
    MigrationRunner.replay!(@version)
  end

  defp surviving_uids(integration, summary) do
    Repo.all(
      from(p in ProviderCalendarEventSchema,
        where: p.calendar_integration_id == ^integration.id and p.summary == ^summary,
        select: p.uid
      )
    )
  end

  defp insert_raw_timed(integration, attrs) do
    Repo.query!(
      """
      INSERT INTO provider_calendar_events
        (calendar_integration_id, provider, provider_calendar_id, uid,
         summary, start_at, end_at, status, transparency, all_day,
         synced_at, inserted_at, updated_at)
      VALUES ($1, 'caldav', 'cal-1', $2, $3, $4, $5,
              'confirmed', 'opaque', false, $6, now(), now())
      """,
      [
        integration.id,
        Map.fetch!(attrs, :uid),
        Map.get(attrs, :summary),
        Map.fetch!(attrs, :start_at),
        Map.fetch!(attrs, :end_at),
        Map.fetch!(attrs, :synced_at)
      ]
    )
  end

  defp insert_raw_all_day(integration, attrs) do
    Repo.query!(
      """
      INSERT INTO provider_calendar_events
        (calendar_integration_id, provider, provider_calendar_id, uid,
         summary, start_date, end_date, status, transparency, all_day,
         synced_at, inserted_at, updated_at)
      VALUES ($1, 'caldav', 'cal-1', $2, $3, $4, $5,
              'confirmed', 'opaque', true, $6, now(), now())
      """,
      [
        integration.id,
        Map.fetch!(attrs, :uid),
        Map.get(attrs, :summary),
        Map.fetch!(attrs, :start_date),
        Map.fetch!(attrs, :end_date),
        Map.fetch!(attrs, :synced_at)
      ]
    )
  end
end
