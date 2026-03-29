defmodule Tymeslot.Repo.Migrations.BackfillCalendarProviderAccountId do
  use Ecto.Migration

  @doc """
  Repair migration for users who successfully ran 20260323000001 without the
  CalDAV backfill. Those installations have the null-guard index in place but
  calendar_integrations rows may still have NULL provider_account_id.

  For fresh installs and users who failed on 20260323000001, the patched
  original migration already handles this — so every step here is idempotent.
  """

  def up do
    # Backfill CalDAV-family rows that still have NULL provider_account_id.
    # Uses a single UPDATE with a window function so there is no intermediate
    # state that could violate the existing unique_active_calendar_account_per_user
    # index (which covers rows where provider_account_id IS NOT NULL).
    execute("""
    UPDATE calendar_integrations ci
    SET provider_account_id = CASE
      WHEN sub.rn = 1 THEN sub.base_url
      ELSE sub.base_url || '||' || ci.id
    END
    FROM (
      SELECT id, base_url,
        ROW_NUMBER() OVER (
          PARTITION BY user_id, provider, base_url
          ORDER BY id
        ) AS rn
      FROM calendar_integrations
      WHERE provider IN ('caldav', 'radicale', 'nextcloud', 'zimbra')
        AND base_url IS NOT NULL
        AND provider_account_id IS NULL
    ) sub
    WHERE ci.id = sub.id
    """)

    # Create the null-guard index if it doesn't already exist.
    # Users who ran the original successfully already have it; users who
    # failed (and now got the patched original) also already have it.
    # This catches any edge case where neither applied.
    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS unique_active_calendar_null_account_per_user
    ON calendar_integrations (user_id, provider)
    WHERE is_active = true AND provider_account_id IS NULL
    """)
  end

  def down do
    # The backfill is non-destructive — no rollback needed.
    # The index is managed by the original migration's down/0.
    :ok
  end
end
