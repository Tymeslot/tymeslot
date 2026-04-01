defmodule Tymeslot.Repo.Migrations.AllowNullProfileTimezone do
  use Ecto.Migration

  def change do
    alter table(:profiles) do
      modify :timezone, :string,
        null: true,
        default: nil,
        from: {:string, null: false, default: "Europe/Tallinn"}
    end
  end
end
