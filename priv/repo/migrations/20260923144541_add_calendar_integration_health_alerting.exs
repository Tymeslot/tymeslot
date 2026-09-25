defmodule Tymeslot.Repo.Migrations.AddCalendarIntegrationHealthAlerting do
  use Ecto.Migration

  @moduledoc """
  Records the two calendar health facts `HealthCheck.Alerting` counts and
  nothing recorded before:

    * `calendar_availability_refusals`: per organiser, per clock hour, how many
      availability computations failed closed because a selected calendar
      could not be read
    * `calendar_integrations.reauth_flagged_at`: when `needs_reauth` last went
      from false to true

  Existing integrations have no recorded flag time, so the column starts empty:
  an integration flagged before this migration is not a new flag.
  """

  # The references and indexes are created against a table this same migration
  # creates: it holds no rows yet, so there is no lock contention to avoid by
  # adding them concurrently or in a later migration. The column added to
  # `calendar_integrations` is nullable with no default, a metadata-only change.
  # excellent_migrations:safety-assured-for-this-file column_reference_added
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  def change do
    create table(:calendar_availability_refusals) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)
      add(:bucket_start, :utc_datetime, null: false)
      add(:refusals, :integer, null: false)

      timestamps(type: :utc_datetime)
    end

    # One counter per organiser per hour, incremented in place.
    create(unique_index(:calendar_availability_refusals, [:user_id, :bucket_start]))
    # Window sums and retention pruning both range over the hour.
    create(index(:calendar_availability_refusals, [:bucket_start]))

    alter table(:calendar_integrations) do
      add(:reauth_flagged_at, :utc_datetime)
    end
  end
end
