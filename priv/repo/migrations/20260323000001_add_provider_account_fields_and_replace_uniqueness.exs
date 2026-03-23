defmodule Tymeslot.Repo.Migrations.AddProviderAccountFieldsAndReplaceUniqueness do
  use Ecto.Migration

  def up do
    # Add new columns to video_integrations
    alter table(:video_integrations) do
      add :provider_account_id, :string, size: 255
      add :provider_account_email, :string, size: 255
    end

    # Add new columns to calendar_integrations
    alter table(:calendar_integrations) do
      add :provider_account_id, :string, size: 255
      add :provider_account_email, :string, size: 255
    end

    # Backfill custom video integrations
    execute """
    UPDATE video_integrations
    SET provider_account_id = custom_meeting_url
    WHERE provider = 'custom' AND custom_meeting_url IS NOT NULL
    """

    # Backfill mirotalk integrations
    execute """
    UPDATE video_integrations
    SET provider_account_id = base_url
    WHERE provider = 'mirotalk' AND base_url IS NOT NULL
    """

    # Drop the old per-provider constraint
    drop_if_exists index(:video_integrations, [:user_id, :provider],
                     name: :one_active_integration_per_user_provider)

    # Create new per-account constraints
    create unique_index(:video_integrations, [:user_id, :provider, :provider_account_id],
      where: "is_active = true AND provider_account_id IS NOT NULL",
      name: :unique_active_video_account_per_user
    )

    create unique_index(:calendar_integrations, [:user_id, :provider, :provider_account_id],
      where: "is_active = true AND provider_account_id IS NOT NULL",
      name: :unique_active_calendar_account_per_user
    )
  end

  def down do
    drop_if_exists index(:video_integrations, [:user_id, :provider, :provider_account_id],
                     name: :unique_active_video_account_per_user)

    drop_if_exists index(:calendar_integrations, [:user_id, :provider, :provider_account_id],
                     name: :unique_active_calendar_account_per_user)

    # Restore old constraint (best-effort; may fail if duplicates now exist)
    create unique_index(:video_integrations, [:user_id, :provider],
      where: "is_active = true",
      name: :one_active_integration_per_user_provider
    )

    alter table(:video_integrations) do
      remove :provider_account_id
      remove :provider_account_email
    end

    alter table(:calendar_integrations) do
      remove :provider_account_id
      remove :provider_account_email
    end
  end
end
