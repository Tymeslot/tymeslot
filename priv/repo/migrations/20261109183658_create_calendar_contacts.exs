defmodule Tymeslot.Repo.Migrations.CreateCalendarContacts do
  use Ecto.Migration

  @moduledoc """
  The names and addresses synced from the address books of a calendar
  connection that suggests contacts (`Tymeslot.Contacts`), so a search while
  the host types reads the database rather than asking the server.

  An address book is a row of its own, with the token the server last
  described it by, so a sync lists only the books that changed. Its
  contacts go with it, and both go with the connection: turning suggestions
  off, disconnecting the calendar or deleting the account removes them.
  Names and addresses are encrypted at rest, like the connection's
  credentials.
  """

  def change do
    create table(:calendar_contact_books) do
      add :calendar_integration_id,
          references(:calendar_integrations, on_delete: :delete_all),
          null: false

      add :href, :string, size: 2048, null: false
      add :sync_token, :string, size: 2048

      timestamps(type: :utc_datetime)
    end

    create unique_index(:calendar_contact_books, [:calendar_integration_id, :href])

    create table(:calendar_contacts) do
      add :calendar_contact_book_id,
          references(:calendar_contact_books, on_delete: :delete_all),
          null: false

      add :name_encrypted, :binary
      add :email_encrypted, :binary, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:calendar_contacts, [:calendar_contact_book_id])
  end
end
