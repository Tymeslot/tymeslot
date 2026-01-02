defmodule Tymeslot.Repo.Migrations.CreateThemeCustomizations do
  use Ecto.Migration

  def change do
    create table(:theme_customizations) do
      add :profile_id, references(:profiles, on_delete: :delete_all), null: false
      add :color_scheme, :string, null: false, default: "default"
      add :background_type, :string, null: false, default: "gradient"
      add :background_value, :text
      add :background_image_path, :string
      add :background_video_path, :string

      timestamps()
    end

    create unique_index(:theme_customizations, [:profile_id])
    create index(:theme_customizations, [:color_scheme])
    create index(:theme_customizations, [:background_type])

    # Add has_custom_theme to profiles
    alter table(:profiles) do
      add :has_custom_theme, :boolean, default: false, null: false
    end

    create index(:profiles, [:has_custom_theme])
  end
end