defmodule Tymeslot.Repo.Migrations.ReactivateCalendarsDeactivatedByTokenRefresh do
  @moduledoc """
  Reactivates the Google and Outlook calendar integrations that
  `TokenRefreshJob` deactivated on a permanent refresh failure, so the paths
  that ask their owners to reconnect can reach them.

  Until this release, a refresh the provider refused for good (a revoked or
  expired grant, a rejected client) set `is_active: false` instead of flagging
  the integration for reconnection. That stranded it: the dashboard showed it
  as paused, as though the owner had chosen that; no reconnection email went
  out; and the health probe, the sync sweep and the refresh job all skip
  inactive integrations, so nothing could ever revise the verdict. The job now
  flags such an integration and leaves it active.

  This undoes the old write and nothing more. Once active again, the next
  refresh, sync or health probe meets the same refusal and handles it the new
  way: it flags the integration, records why, and emails the owner once. The
  migration deliberately does not set `needs_reauth` itself, because that
  flag is what suppresses the email, and the owners these rows belong to were
  never told.

  ## Which rows

  Exactly the ones the old code produced: inactive, not already flagged, and
  carrying the `sync_error` it wrote, `"<Provider> integration failed during
  token refresh: <reason> (PERMANENT)"`. Nothing else writes that suffix. A
  row the owner paused on purpose after the failure is indistinguishable
  and is reactivated too; it is broken either way, and the flag that follows
  asks its owner to reconnect or remove it.

  ## Which rows are skipped

  Both uniqueness indexes on this table are predicated on `is_active = true`
  (`unique_active_calendar_account_per_user` on
  `(user_id, provider, provider_account_id)`, and
  `unique_active_calendar_null_account_per_user` on `(user_id, provider)` for
  rows whose account id is NULL), so reactivating a row moves it into one of
  them. The application refuses a reactivation that would collide
  (`CalendarIntegrationQueries.toggle_active/1`); this migration has to be as
  careful, because a `unique_violation` here fails the migration, and
  `start.sh` runs migrations before serving, so the container would never
  come up. A stranded row is therefore left exactly as it was when the same
  account is already active for its owner (typically because they reconnected
  it after the failure), and when several stranded rows share an account only
  the most recently updated one comes back. Such rows are already what the
  owner would be asked to reconnect or remove; nothing is lost by leaving them
  paused.

  Rolling back leaves the rows active: deactivating them again would
  re-create the stranding this repairs.
  """

  use Ecto.Migration

  def up do
    # A bounded one-shot repair of rows only a previous release could write;
    # an `UPDATE` with a predicate on a text column has no migration DSL form.
    #
    # One statement, so the `NOT EXISTS` reads the table as it stood before
    # any row was reactivated; the window rank is what keeps two stranded
    # rows of one account from both coming back. `IS NOT DISTINCT FROM`
    # treats two NULL account ids as the same account, matching the NULL
    # index, and `PARTITION BY` groups NULLs the same way.
    # excellent_migrations:safety-assured-for-next-line raw_sql_executed
    execute("""
    UPDATE calendar_integrations AS ci
    SET is_active = true, updated_at = NOW()
    FROM (
      SELECT id,
             ROW_NUMBER() OVER (
               PARTITION BY user_id, provider, provider_account_id
               ORDER BY updated_at DESC, id
             ) AS rank
      FROM calendar_integrations
      WHERE provider IN ('google', 'outlook')
        AND is_active = false
        AND needs_reauth = false
        AND sync_error LIKE '% integration failed during token refresh: % (PERMANENT)'
    ) AS stranded
    WHERE ci.id = stranded.id
      AND stranded.rank = 1
      AND NOT EXISTS (
        SELECT 1
        FROM calendar_integrations active
        WHERE active.user_id = ci.user_id
          AND active.provider = ci.provider
          AND active.provider_account_id IS NOT DISTINCT FROM ci.provider_account_id
          AND active.is_active = true
      )
    """)
  end

  def down, do: :ok
end
