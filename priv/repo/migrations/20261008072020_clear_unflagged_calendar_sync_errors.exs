defmodule Tymeslot.Repo.Migrations.ClearUnflaggedCalendarSyncErrors do
  @moduledoc """
  Forgets the last sync failure recorded on every calendar integration that
  is not awaiting reconnection.

  A calendar card now shows its stored `sync_error` once its syncs keep
  failing, and translates it by looking it up as a msgid. Before this
  release the field also held text built from the failure: an exception's
  message (a subscription's database error included), an HTTP status, a
  server's own fault text, or a token refresh reason. Such a row would show
  that text as soon as its card turned unhealthy, and a Google or Outlook
  row could keep showing it until the next token refresh, since their sync
  workers do not write the field.

  Nothing is lost: the next failure records its reason again, as a msgid.
  A flagged integration keeps its reason, which its card shows already and
  which is the one thing its owner has to act on.

  Rolling back leaves the field empty; the text cleared is not kept.
  """

  use Ecto.Migration

  def up do
    # A one-shot clean-up of a free-text column; an `UPDATE` with a
    # predicate has no migration DSL form.
    # excellent_migrations:safety-assured-for-next-line raw_sql_executed
    execute("""
    UPDATE calendar_integrations
    SET sync_error = NULL
    WHERE needs_reauth = false
      AND sync_error IS NOT NULL
    """)
  end

  def down, do: :ok
end
