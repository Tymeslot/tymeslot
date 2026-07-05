defmodule Tymeslot.Repo.Migrations.CreateEventColourOverrides do
  use Ecto.Migration

  def change do
    create_if_not_exists table(:event_colour_overrides) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      add(:colour, :string, null: false)
      add(:meeting_id, references(:meetings, type: :binary_id, on_delete: :delete_all))
      add(:calendar_integration_id, references(:calendar_integrations, on_delete: :delete_all))
      add(:provider_uid, :string)
      timestamps()
    end

    create_if_not_exists(
      unique_index(:event_colour_overrides, [:user_id, :meeting_id],
        where: "meeting_id IS NOT NULL",
        name: :event_colour_overrides_user_meeting_index
      )
    )

    create_if_not_exists(
      unique_index(
        :event_colour_overrides,
        [:user_id, :calendar_integration_id, :provider_uid],
        where: "provider_uid IS NOT NULL",
        name: :event_colour_overrides_user_external_index
      )
    )

    create(
      constraint(:event_colour_overrides, :event_colour_overrides_exactly_one_target,
        check:
          "((meeting_id IS NOT NULL) AND calendar_integration_id IS NULL AND provider_uid IS NULL) OR (meeting_id IS NULL AND calendar_integration_id IS NOT NULL AND provider_uid IS NOT NULL)"
      )
    )
  end
end
