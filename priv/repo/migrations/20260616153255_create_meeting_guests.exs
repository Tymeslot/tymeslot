defmodule Tymeslot.Repo.Migrations.CreateMeetingGuests do
  use Ecto.Migration

  def change do
    create table(:meeting_guests, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :meeting_id,
          references(:meetings, type: :binary_id, on_delete: :delete_all),
          null: false

      add :email, :string, null: false
      add :name, :string
      add :status, :string, default: "pending", null: false
      add :rsvp_token, :string, null: false
      add :responded_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:meeting_guests, [:meeting_id])
    create unique_index(:meeting_guests, [:rsvp_token])
    create unique_index(:meeting_guests, [:meeting_id, :email])
  end
end
