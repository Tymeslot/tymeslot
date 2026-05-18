defmodule Tymeslot.Repo.Migrations.CreateUserSeenAnnouncements do
  use Ecto.Migration

  def change do
    create table(:user_seen_announcements) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      add(:announcement_key, :string, null: false)
      add(:seen_at, :utc_datetime, null: false)
    end

    create(index(:user_seen_announcements, [:user_id]))
    create(unique_index(:user_seen_announcements, [:user_id, :announcement_key]))
  end
end
