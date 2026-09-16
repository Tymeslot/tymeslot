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

  Rolling back leaves the rows active: deactivating them again would
  re-create the stranding this repairs.
  """

  use Ecto.Migration

  def up do
    # A bounded one-shot repair of rows only a previous release could write;
    # an `UPDATE` with a predicate on a text column has no migration DSL form.
    # excellent_migrations:safety-assured-for-next-line raw_sql_executed
    execute("""
    UPDATE calendar_integrations
    SET is_active = true, updated_at = NOW()
    WHERE provider IN ('google', 'outlook')
      AND is_active = false
      AND needs_reauth = false
      AND sync_error LIKE '% integration failed during token refresh: % (PERMANENT)'
    """)
  end

  def down, do: :ok
end
