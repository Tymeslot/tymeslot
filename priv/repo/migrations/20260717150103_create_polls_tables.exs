defmodule Tymeslot.Repo.Migrations.CreatePollsTables do
  use Ecto.Migration

  def change do
    create table(:polls, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :meeting_type_id, references(:meeting_types, on_delete: :nilify_all)
      add :title, :string, null: false
      add :description, :text
      add :duration_minutes, :integer, null: false
      add :token, :string, null: false
      add :status, :string, null: false, default: "open"
      add :deadline_at, :utc_datetime
      add :timezone, :string, null: false
      add :confirmed_meeting_id, references(:meetings, type: :binary_id, on_delete: :nilify_all)
      add :confirmed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:polls, [:token])
    create index(:polls, [:user_id])
    create index(:polls, [:meeting_type_id])

    create table(:poll_time_slots, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :poll_id, references(:polls, type: :binary_id, on_delete: :delete_all), null: false
      add :start_time, :utc_datetime, null: false
      add :end_time, :utc_datetime, null: false
      add :position, :integer, null: false, default: 0

      timestamps(type: :utc_datetime)
    end

    create index(:poll_time_slots, [:poll_id])
    create unique_index(:poll_time_slots, [:poll_id, :start_time])

    create table(:poll_participants, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :poll_id, references(:polls, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :email, :string, null: false
      add :token, :string, null: false
      add :timezone, :string
      add :locale, :string, null: false, default: "en"
      add :voted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:poll_participants, [:poll_id])
    create unique_index(:poll_participants, [:token])
    create unique_index(:poll_participants, [:poll_id, :email])

    create table(:poll_votes, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :poll_participant_id,
          references(:poll_participants, type: :binary_id, on_delete: :delete_all),
          null: false

      add :poll_time_slot_id,
          references(:poll_time_slots, type: :binary_id, on_delete: :delete_all),
          null: false

      add :response, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:poll_votes, [:poll_time_slot_id])
    create unique_index(:poll_votes, [:poll_participant_id, :poll_time_slot_id])
  end
end
