defmodule Tymeslot.Repo.Migrations.AddSlugAndIsPrivateToMeetingTypes do
  use Ecto.Migration

  # Both columns are self-healing on existing data:
  #   * is_private is NOT NULL with a default, so existing rows become public (false).
  #   * slug is nullable (NULL means "derive the slug from the name"), so existing rows
  #     need no backfill. The unique index is partial (slug IS NOT NULL), and every
  #     existing row has slug NULL, so it cannot collide on first apply.
  def change do
    alter table(:meeting_types) do
      add(:slug, :string)
      add(:is_private, :boolean, default: false, null: false)
    end

    create_if_not_exists(
      unique_index(:meeting_types, [:user_id, :slug],
        where: "slug IS NOT NULL",
        name: :meeting_types_user_id_slug_index
      )
    )
  end
end
