defmodule Tymeslot.Repo.Migrations.AddVideoProcessingToThemeCustomizations do
  use Ecto.Migration

  def change do
    alter table(:theme_customizations) do
      add :video_processing, :string
    end
  end
end
