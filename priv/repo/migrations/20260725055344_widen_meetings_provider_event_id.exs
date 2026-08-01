defmodule Tymeslot.Repo.Migrations.WidenMeetingsProviderEventId do
  use Ecto.Migration

  def change do
    # Google Calendar permits event ids up to 1024 characters, so varchar(255)
    # can reject a provider-issued id at the database layer. Widening
    # varchar -> text is a catalogue-only change in PostgreSQL: no table
    # rewrite, no scan, only a brief metadata lock.
    alter table(:meetings) do
      # excellent_migrations:safety-assured-for-next-line column_type_changed
      modify(:provider_event_id, :text, from: :string)
    end
  end
end
