defmodule Tymeslot.Repo.Migrations.CreateJobDeliveryClaims do
  # Records which side effects an Oban job has already claimed, so a job the
  # lifeline plugin rescues does not repeat an email, message or post it
  # already made. See `Tymeslot.Workers.DeliveryClaims`.
  #
  # `oban_job_id` deliberately has no foreign key to `oban_jobs`: a job that is
  # run without ever being inserted (`Oban.Testing.perform_job/2`) still carries
  # an id, and a claim for it must not fail. Claims whose job Oban has since
  # pruned are deleted by `Tymeslot.Workers.ObanMaintenanceWorker` instead.

  use Ecto.Migration

  # The index is on a table this migration creates, so it is empty and the
  # build is instant.
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently

  def change do
    create table(:job_delivery_claims) do
      add(:oban_job_id, :bigint, null: false)
      add(:effect_key, :string, null: false)

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create(unique_index(:job_delivery_claims, [:oban_job_id, :effect_key]))
  end
end
