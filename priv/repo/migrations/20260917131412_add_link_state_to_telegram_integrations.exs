defmodule Tymeslot.Repo.Migrations.AddLinkStateToTelegramIntegrations do
  @moduledoc """
  Records whether a Telegram integration was ever linked to a chat, and when
  its current link token was issued.

  An empty `chat_id` used to mean "a setup stub nobody finished", and stubs
  older than half an hour are deleted when the list loads. Disconnecting an
  integration also empties `chat_id`, so a disconnected integration was
  deleted along with its delivery log the next time the page reloaded.
  `linked_at` tells the two apart: a stub has never been linked, a
  disconnected integration has.

  `link_token_issued_at` lets link tokens expire on the server. A disconnected
  integration now survives indefinitely while holding a token, and a deep link
  that leaked must not be able to bind a chat to it forever.

  ## Backfill

  An integration counts as linked if it has a chat, has ever delivered a
  message (`last_triggered_at`), has a delivery log row, or holds no link
  token. The last of those catches the rest: every unfinished stub carries the
  token its setup generated, and linking a chat clears it, so an integration
  with neither a chat nor a token is one that was linked and later
  disconnected. Without it, a chat that was linked and disconnected before any
  delivery succeeded reads as a stub and is deleted, taking its configuration
  with it.

  A linked integration is stamped with `updated_at`, the latest moment by
  which it had certainly been linked; the exact moment was never recorded.

  A token that is already outstanding is stamped with `updated_at` too, the
  last write to the row and so no earlier than the token itself. An in-flight
  link keeps working for the rest of its window, and older tokens expire.

  Rolling back drops both columns.
  """

  use Ecto.Migration

  def up do
    alter table(:telegram_integrations) do
      add_if_not_exists(:linked_at, :utc_datetime)
      add_if_not_exists(:link_token_issued_at, :utc_datetime)
    end

    # A one-shot backfill over a small per-user table; an `UPDATE` with an
    # `EXISTS` subquery has no migration DSL form. Both statements only fill
    # NULLs, so re-running them is harmless.
    # excellent_migrations:safety-assured-for-next-line raw_sql_executed
    execute("""
    UPDATE telegram_integrations AS ti
    SET linked_at = ti.updated_at
    WHERE ti.linked_at IS NULL
      AND (
        ti.chat_id IS NOT NULL
        OR ti.last_triggered_at IS NOT NULL
        OR ti.link_token IS NULL
        OR EXISTS (SELECT 1 FROM telegram_deliveries d WHERE d.integration_id = ti.id)
      )
    """)

    # excellent_migrations:safety-assured-for-next-line raw_sql_executed
    execute("""
    UPDATE telegram_integrations
    SET link_token_issued_at = updated_at
    WHERE link_token IS NOT NULL
      AND link_token_issued_at IS NULL
    """)
  end

  def down do
    # Rollback only drops the columns this migration added; nothing that
    # predates it reads them.
    alter table(:telegram_integrations) do
      # excellent_migrations:safety-assured-for-next-line column_removed
      remove_if_exists(:link_token_issued_at, :utc_datetime)
      # excellent_migrations:safety-assured-for-next-line column_removed
      remove_if_exists(:linked_at, :utc_datetime)
    end
  end
end
