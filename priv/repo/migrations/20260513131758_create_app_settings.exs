defmodule Tymeslot.Repo.Migrations.CreateAppSettings do
  use Ecto.Migration

  def change do
    create table(:app_settings) do
      add(:registration_enabled, :boolean)
      add(:password_auth_enabled, :boolean)
      add(:video_transcoding_enabled, :boolean)

      timestamps(type: :utc_datetime_usec)
    end

    create(constraint(:app_settings, :app_settings_singleton, check: "id = 1"))

    execute(
      "INSERT INTO app_settings (id, inserted_at, updated_at) VALUES (1, (NOW() AT TIME ZONE 'UTC'), (NOW() AT TIME ZONE 'UTC'))",
      "DELETE FROM app_settings WHERE id = 1"
    )
  end
end
