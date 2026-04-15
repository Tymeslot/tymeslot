defmodule Tymeslot.Integrations.Calendar.ProviderCalendarEventCleanupTest do
  @moduledoc """
  Tests the SQL from the cleanup migration that:

  - Remaps `status='free'` rows to `(status='confirmed', transparency='transparent')`
  - De-duplicates `(calendar_integration_id, summary, start_at, end_at)` clusters
  - Enforces CHECK constraints on `status` and `transparency`

  Runs non-async because it temporarily drops the CHECK constraints to
  simulate the pre-migration database state and insert adversarial rows.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :calendar

  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Repo

  @normalise_free_sql """
  UPDATE provider_calendar_events
     SET status = 'confirmed',
         transparency = 'transparent'
   WHERE status = 'free'
  """

  @dedupe_timed_sql """
  WITH ranked AS (
    SELECT id,
           ROW_NUMBER() OVER (
             PARTITION BY calendar_integration_id, summary, start_at, end_at
             ORDER BY synced_at DESC NULLS LAST, id DESC
           ) AS rn
      FROM provider_calendar_events
     WHERE summary IS NOT NULL
       AND start_at IS NOT NULL
       AND end_at IS NOT NULL
  )
  DELETE FROM provider_calendar_events
   WHERE id IN (SELECT id FROM ranked WHERE rn > 1)
  """

  @dedupe_all_day_sql """
  WITH ranked AS (
    SELECT id,
           ROW_NUMBER() OVER (
             PARTITION BY calendar_integration_id, summary, start_date, end_date
             ORDER BY synced_at DESC NULLS LAST, id DESC
           ) AS rn
      FROM provider_calendar_events
     WHERE all_day = true
       AND summary IS NOT NULL
       AND start_date IS NOT NULL
       AND end_date IS NOT NULL
  )
  DELETE FROM provider_calendar_events
   WHERE id IN (SELECT id FROM ranked WHERE rn > 1)
  """

  setup do
    # Drop the CHECK constraints so we can insert adversarial rows that
    # the migration is supposed to clean up.
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

      Repo.query!(@normalise_free_sql)

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

      Repo.query!(@dedupe_timed_sql)

      # Only the newest survivor remains.
      survivors =
        Repo.all(
          from p in ProviderCalendarEventSchema,
            where: p.calendar_integration_id == ^integration.id and p.summary == "Dup event",
            select: p.uid
        )

      assert survivors == ["dup-uid-newest"]
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

      Repo.query!(@dedupe_all_day_sql)

      survivors =
        Repo.all(
          from p in ProviderCalendarEventSchema,
            where: p.calendar_integration_id == ^integration.id and p.summary == "Holiday",
            select: p.uid
        )

      assert survivors == ["allday-new"]
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

      Repo.query!(@dedupe_all_day_sql)

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

      Repo.query!(@dedupe_timed_sql)

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

      Repo.query!(@dedupe_timed_sql)

      assert Repo.get_by(ProviderCalendarEventSchema, uid: "null-summary-a")
      assert Repo.get_by(ProviderCalendarEventSchema, uid: "null-summary-b")
    end
  end

  describe "CHECK constraints" do
    test "reject invalid status values once installed", %{integration: integration} do
      Repo.query!("""
      ALTER TABLE provider_calendar_events
        ADD CONSTRAINT provider_calendar_events_status_check
        CHECK (status IS NULL OR status IN ('confirmed', 'tentative', 'cancelled', 'declined'))
      """)

      on_exit(fn ->
        Repo.query!(
          "ALTER TABLE provider_calendar_events DROP CONSTRAINT IF EXISTS provider_calendar_events_status_check"
        )
      end)

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
      Repo.query!("""
      ALTER TABLE provider_calendar_events
        ADD CONSTRAINT provider_calendar_events_transparency_check
        CHECK (transparency IS NULL OR transparency IN ('opaque', 'transparent'))
      """)

      on_exit(fn ->
        Repo.query!(
          "ALTER TABLE provider_calendar_events DROP CONSTRAINT IF EXISTS provider_calendar_events_transparency_check"
        )
      end)

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
