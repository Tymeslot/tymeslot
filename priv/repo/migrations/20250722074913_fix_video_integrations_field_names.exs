defmodule Tymeslot.Repo.Migrations.FixVideoIntegrationsFieldNames do
  use Ecto.Migration

  def change do
    # Remove the incorrectly named field if it exists
    alter table(:video_integrations) do
      remove_if_exists :user_id_encrypted, :binary
    end
    
    # The teams_user_id_encrypted field was already added in the previous migration
    # No need to add it again
  end
end