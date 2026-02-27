defmodule Tymeslot.Repo.Migrations.UpdateProfilesDefaultTimezone do
  use Ecto.Migration

  def change do
    alter table(:profiles) do
      modify :timezone, :string,
        default: "Europe/Tallinn",
        null: false,
        from: {:string, default: "Europe/Kyiv", null: false}
    end
  end
end
