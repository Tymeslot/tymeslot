defmodule Tymeslot.Repo.Migrations.CascadeDeleteMeetingsOnUserDelete do
  use Ecto.Migration

  def change do
    drop constraint(:meetings, "meetings_organizer_user_id_fkey")

    alter table(:meetings) do
      modify :organizer_user_id, references(:users, on_delete: :delete_all), null: true
    end
  end
end
