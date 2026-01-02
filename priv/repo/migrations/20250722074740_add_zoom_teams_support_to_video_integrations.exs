defmodule Tymeslot.Repo.Migrations.AddZoomTeamsSupportToVideoIntegrations do
  use Ecto.Migration

  def change do
    # Add fields needed for Zoom integration
    alter table(:video_integrations) do
      add :account_id_encrypted, :binary  # Zoom Account ID
      add :client_id_encrypted, :binary   # OAuth Client ID (Zoom/Teams)
      add :client_secret_encrypted, :binary # OAuth Client Secret (Zoom/Teams)
      
      # Add fields needed for Microsoft Teams integration
      add :tenant_id_encrypted, :binary   # Azure AD Tenant ID
      add :teams_user_id_encrypted, :binary # Teams User ID/UPN
      
      # Add field for custom video meeting URLs
      add :custom_meeting_url, :string
      
      # Remove NOT NULL constraint from base_url to support other providers
      modify :base_url, :string, null: true
    end
    
    # Add index for efficient queries
    create index(:video_integrations, [:provider])
  end
end