defmodule Tymeslot.Repo.Migrations.AddCustomPaletteSeedToThemeCustomizations do
  use Ecto.Migration

  def change do
    alter table(:theme_customizations) do
      add :custom_palette_seed, :string
    end
  end
end
