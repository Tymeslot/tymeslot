defmodule Tymeslot.Repo.Migrations.RebuildInvalidConcurrentIndexes do
  @moduledoc """
  Rebuilds any index that an interrupted `CREATE INDEX CONCURRENTLY` left
  invalid, for every concurrently-built index older than the boot-time
  `Tymeslot.Infrastructure.IndexHealth` check.

  The failure mode is the one `20260911153135_rebuild_provider_event_id_index_if_invalid`
  repaired for a single index. A concurrent build cannot run in a transaction,
  so an interruption leaves the half-built index marked
  `pg_index.indisvalid = false`. The migration fails without recording its
  version; on the next boot `IF NOT EXISTS` finds an index of that name, skips
  the create, and records the version, so the planner ignores the index for
  ever on that installation. Dropping first is what breaks the cycle, and it
  also makes this migration heal itself: interrupted part way, it leaves at
  worst another invalid index, which the next run drops and builds again.

  Each rebuild is guarded on `indisvalid`, read from the catalogue with
  `repo().query!/2` (a read, so no `excellent_migrations` annotation). An
  unguarded drop and create would cost every installation a full rebuild at
  upgrade time, including the `oban_jobs` GIN index, to repair a state almost
  none of them are in. A missing index is left missing: unlike the template,
  this covers indexes from several migrations, and an absent one may have been
  dropped on purpose.

  ## Which indexes

  Every index built concurrently by `20250914085000`, `20260209000000`,
  `20260508170000`, `20260511084157`, `20260511110130` and `20260616144719`,
  with two exclusions:

    * `20250914085000`'s four default-named `meetings` indexes (`uid`,
      `status`, `start_time`, `end_time`). `20250701180112_create_meetings`
      had already built them inside its transaction, so the concurrent
      `create_if_not_exists` never ran for them on any installation.
    * `unique_booking_calendar_per_user` from `20250912151120`, dropped by
      `20260115143000_allow_multiple_booking_calendars`.

  Each definition below is transcribed from its original migration, name,
  uniqueness and predicate included, and the migration test compares every
  rebuilt definition against the catalogue's original. Names are explicit
  throughout: a rebuild under a different name would leave the invalid index
  in place and add a second one.

  Cheap tables go first and `oban_jobs` last, so an interruption during the
  slowest build has already repaired everything else.

  ## Unique indexes over duplicate rows

  A unique build over data that already violates it fails, and a failed build
  is one plausible way these indexes became invalid in the first place.
  Rebuilding would then fail the migration and stop the release booting,
  which is worse than the slow query the invalid index costs. So a unique
  index is rebuilt only when no duplicates exist; otherwise it is left
  invalid with a warning, and `IndexHealth` keeps naming it at every boot.
  Choosing which duplicate survives (these are Stripe Connect accounts) is an
  operator's decision, not a migration's.
  """

  use Ecto.Migration

  require Logger

  @disable_ddl_transaction true
  @disable_migration_lock true

  @indexes [
    {:payment_transactions, [:host_deleted_at],
     name: :payment_transactions_host_deleted_at_index},
    {:booking_payments, [:status, :inserted_at],
     name: :booking_payments_stale_pending_index,
     where: "status = 'pending' AND stripe_checkout_session_id IS NOT NULL"},
    {:connect_accounts, [:user_id],
     name: :connect_accounts_user_id_live_unique_index, unique: true, where: "deleted_at IS NULL"},
    {:connect_accounts, [:stripe_account_id],
     name: :connect_accounts_stripe_account_id_live_unique_index,
     unique: true,
     where: "stripe_account_id IS NOT NULL AND deleted_at IS NULL"},
    {:meetings, [:organizer_email, :start_time], name: :idx_meetings_organizer_email_start_time},
    {:meetings, [:attendee_email, :start_time], name: :idx_meetings_attendee_email_start_time},
    {:meetings, [:start_time],
     name: :idx_meetings_reminders_due,
     where: "status = 'confirmed' AND reminder_email_sent = false"},
    {:meetings, [:organizer_user_id, :utm_source],
     name: :meetings_organizer_utm_source_index, where: "utm_source IS NOT NULL"},
    {:oban_jobs, [:state, :queue, :inserted_at],
     name: :idx_oban_jobs_monitoring, where: "state IN ('available', 'retryable')"},
    {:oban_jobs, [:state, :queue, :scheduled_at, :inserted_at],
     name: :idx_oban_jobs_scheduled_monitoring, where: "state = 'retryable'"},
    {:oban_jobs, [:args], name: :idx_oban_jobs_args_gin, using: "gin"}
  ]

  def up do
    Enum.each(@indexes, fn {table, columns, opts} ->
      if index_state(opts[:name]) == :invalid, do: rebuild(table, columns, opts)
    end)
  end

  def down do
    # Deliberately a no-op. This migration owns none of these indexes; it only
    # rebuilds what earlier migrations created, so rolling it back must leave
    # them for those migrations' own `down/0` to drop.
    :ok
  end

  defp rebuild(table, columns, opts) do
    if opts[:unique] && duplicates?(table, columns, opts[:where]) do
      Logger.warning(
        "Leaving invalid unique index #{opts[:name]} in place: #{table} holds rows that " <>
          "violate it. Resolve the duplicates, then run REINDEX INDEX CONCURRENTLY #{opts[:name]}."
      )
    else
      drop_if_exists(index(table, columns, name: opts[:name], concurrently: true))

      create(
        index(table, columns,
          name: opts[:name],
          unique: Keyword.get(opts, :unique, false),
          where: opts[:where],
          using: opts[:using],
          concurrently: true
        )
      )
    end
  end

  # `to_regclass/1` resolves the name through the migration's search path and
  # returns NULL for a relation that does not exist, so a missing index comes
  # back as no row rather than an error.
  defp index_state(name) do
    %{rows: rows} =
      repo().query!("SELECT indisvalid FROM pg_index WHERE indexrelid = to_regclass($1)", [
        Atom.to_string(name)
      ])

    case rows do
      [] -> :missing
      [[true]] -> :valid
      [[false]] -> :invalid
    end
  end

  # NULLs never collide in a unique index, so rows with a NULL key are left out
  # of the grouping. Table, columns and predicate are the literals above.
  defp duplicates?(table, columns, where) do
    column_list = Enum.map_join(columns, ", ", &Atom.to_string/1)
    not_null = Enum.map_join(columns, " AND ", &"#{&1} IS NOT NULL")

    %{rows: [[exists]]} =
      repo().query!("""
      SELECT EXISTS (
        SELECT 1 FROM #{table}
        WHERE (#{where || "TRUE"}) AND #{not_null}
        GROUP BY #{column_list}
        HAVING count(*) > 1
      )
      """)

    exists
  end
end
