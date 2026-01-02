defmodule Tymeslot.Repo.Migrations.AddThemeIdToCustomizations do
  use Ecto.Migration

  def up do
    # Add theme_id column
    alter table(:theme_customizations) do
      add :theme_id, :string, null: false, default: "1"
    end

    # Remove old unique index on profile_id
    drop_if_exists unique_index(:theme_customizations, [:profile_id])
    
    # Add new composite unique index
    create unique_index(:theme_customizations, [:profile_id, :theme_id])
    
    # Add index on theme_id for queries
    create index(:theme_customizations, [:theme_id])
  end

  def down do
    # Remove new indexes
    drop_if_exists unique_index(:theme_customizations, [:profile_id, :theme_id])
    drop_if_exists index(:theme_customizations, [:theme_id])
    
    # Add back old unique index
    create unique_index(:theme_customizations, [:profile_id])
    
    # Remove theme_id column
    alter table(:theme_customizations) do
      remove :theme_id
    end
  end
end