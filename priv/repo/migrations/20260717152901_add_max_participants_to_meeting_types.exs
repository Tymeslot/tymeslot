defmodule Tymeslot.Repo.Migrations.AddMaxParticipantsToMeetingTypes do
  use Ecto.Migration

  def change do
    alter table(:meeting_types) do
      # `1` is a constant, not a volatile expression, so from PostgreSQL 11
      # onwards this is a catalogue-only change: the default is recorded once
      # and existing rows read it without a table rewrite. The project requires
      # PostgreSQL 14 or newer (README), so every supported version takes the
      # cheap path. Migrations also run offline — `start.sh` runs them in a
      # one-shot VM and only then starts Phoenix.
      # excellent_migrations:safety-assured-for-next-line column_added_with_default
      add :max_participants, :integer, default: 1, null: false
    end
  end
end
