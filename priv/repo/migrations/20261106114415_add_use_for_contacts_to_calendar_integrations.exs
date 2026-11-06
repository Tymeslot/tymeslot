defmodule Tymeslot.Repo.Migrations.AddUseForContactsToCalendarIntegrations do
  use Ecto.Migration

  @moduledoc """
  Lets a calendar connection's address books suggest contacts wherever its
  owner types in whom to invite (`Tymeslot.Contacts`). Off for every
  existing row, so nothing is read from an address book until the owner
  turns it on.
  """

  # excellent_migrations:safety-assured-for-this-file column_added_with_default
  # Migrations run offline: start.sh executes them in a one-shot VM before
  # Phoenix starts, so no request contends for the lock. The default is a
  # constant, which Postgres 11+ records in the catalogue without rewriting
  # the table.

  def change do
    alter table(:calendar_integrations) do
      add(:use_for_contacts, :boolean, null: false, default: false)
    end
  end
end
