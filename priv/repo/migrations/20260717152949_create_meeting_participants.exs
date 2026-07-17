defmodule Tymeslot.Repo.Migrations.CreateMeetingParticipants do
  use Ecto.Migration

  def change do
    create table(:meeting_participants, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :meeting_id,
          references(:meetings, type: :binary_id, on_delete: :delete_all),
          null: false

      add :name, :string, null: false
      add :email, :string, null: false
      add :phone, :string
      add :company, :string
      add :message, :text
      add :timezone, :string, null: false
      add :locale, :string, default: "en", null: false
      add :custom_field_answers, :map, default: %{}, null: false
      add :management_token, :string, null: false
      add :cancelled_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:meeting_participants, [:meeting_id])
    create unique_index(:meeting_participants, [:management_token])
  end
end
