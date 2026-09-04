defmodule Tymeslot.Repo.Migrations.AddExchangeSyncStatesToCalendarIntegrations do
  @moduledoc """
  Stores the EWS `SyncFolderItems` state token per calendar folder.

  One column rather than one row per folder, and a map rather than a string,
  because the token is folder-scoped while every other sync marker on this
  table is integration-scoped: an Exchange mailbox syncs each selected folder
  separately and each has its own token. `google_sync_token` and
  `graph_delta_link` next to it are single values for exactly that reason —
  those providers hand out one token per account.

  Nullable with no database default. Backfilling `{}` over every existing row
  would rewrite the table to say what a null already says here: no folder has
  been synced incrementally yet, so the first cycle enumerates each in full.
  The schema defaults it to an empty map on read.
  """

  use Ecto.Migration

  def change do
    alter table(:calendar_integrations) do
      add(:exchange_sync_states, :map)
    end
  end
end
