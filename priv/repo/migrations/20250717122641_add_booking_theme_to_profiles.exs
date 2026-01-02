defmodule Tymeslot.Repo.Migrations.AddBookingThemeToProfiles do
  use Ecto.Migration

  def change do
    alter table(:profiles) do
      add :booking_theme, :string, default: "theme1"
    end
  end
end