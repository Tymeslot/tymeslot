defmodule Tymeslot.Repo.Migrations.ConvertNaiveTimestampsToUtc do
  @moduledoc """
  Converts inserted_at/updated_at from `timestamp without time zone` to
  `timestamptz` on tables that used a bare `timestamps()` (naive) call. The
  matching schemas now declare `timestamps(type: :utc_datetime)`, so the
  column type must follow or every read/compare against a DateTime would clash.

  Existing naive values written by Ecto's default `timestamps()` are UTC
  wall-clock, so `col AT TIME ZONE 'UTC'` reinterprets them as the correct
  instant losslessly. The reverse is symmetric.

  KNOWN LIMITATION: this assumption does not hold for every row on every
  table in this list. Two prior migrations backfilled timestamps with raw SQL
  `NOW()` instead of going through Ecto:
  `20250721153548_create_default_availability_for_existing_users` (inserted
  `weekly_availability` rows) and
  `20260317000003_add_unique_active_video_integration_per_user_provider`
  (updated `video_integrations` rows when deactivating duplicates). `NOW()`
  returns a `timestamptz`, and assigning it into a naive column stores the
  wall-clock in the database session's timezone at the time the migration
  ran — not necessarily UTC. On a self-hosted Postgres whose session
  timezone isn't UTC, those specific rows will be off by the session's UTC
  offset after this conversion. This cannot be corrected retroactively: the
  session timezone in effect when those historical migrations ran is not
  recorded anywhere, so there is no way to distinguish a drifted row from a
  correct one after the fact. The blast radius is limited to
  `inserted_at`/`updated_at` bookkeeping columns on default-availability rows
  and deactivated video-integration rows — audit/observability data, not
  scheduling math (booking times live in dedicated `timestamptz` columns
  unaffected by this migration).

  Each ALTER rewrites its table under an ACCESS EXCLUSIVE lock. These are the
  smaller/owner-scoped tables; the large provider_calendar_events cache is
  converted in a separate migration so an operator can schedule it apart.
  """

  use Ecto.Migration

  # Tables carrying both inserted_at and updated_at.
  #
  # NOTE: `weekly_availability` and `video_integrations` include rows written
  # by raw-SQL `NOW()` in prior migrations rather than by Ecto's
  # `timestamps()` — see the moduledoc's "KNOWN LIMITATION" section. Those
  # specific rows may not be true UTC and cannot be distinguished from
  # correct ones after the fact.
  @both ~w(
    connect_accounts
    users
    theme_customizations
    user_sessions
    meeting_types
    booking_payments
    video_integrations
    calendar_integrations
    profiles
    availability_breaks
    availability_overrides
    weekly_availability
    calendar_preferences
  )

  # Tables carrying only inserted_at (timestamps(updated_at: false)).
  @inserted_only ~w(webhook_events)

  def up do
    for table <- @both, col <- ~w(inserted_at updated_at) do
      convert(table, col, "timestamptz", "UTC")
    end

    for table <- @inserted_only do
      convert(table, "inserted_at", "timestamptz", "UTC")
    end
  end

  def down do
    for table <- @both, col <- ~w(inserted_at updated_at) do
      convert(table, col, "timestamp", "UTC")
    end

    for table <- @inserted_only do
      convert(table, "inserted_at", "timestamp", "UTC")
    end
  end

  defp convert(table, col, type, zone) do
    execute(
      "ALTER TABLE #{table} ALTER COLUMN #{col} TYPE #{type} USING #{col} AT TIME ZONE '#{zone}'"
    )
  end
end
