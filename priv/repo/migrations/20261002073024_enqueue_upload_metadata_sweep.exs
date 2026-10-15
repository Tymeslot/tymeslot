defmodule Tymeslot.Repo.Migrations.EnqueueUploadMetadataSweep do
  use Ecto.Migration

  # Uploads have been stripped of location, capture time and device metadata
  # as they are stored since this release; files stored before it still carry
  # theirs and are served publicly. `Tymeslot.Media.UploadMetadataSweep`
  # cleans them, and this queues it once, so an upgraded install is cleaned on
  # its first boot without anyone having to run it by hand.
  #
  # A migration rather than a boot hook because the ledger already records it
  # as done: a job enqueued at every boot under a unique key would come back
  # each time the pruner removed the finished one, and walk every upload again.
  # A fresh install gets the job too and it finds nothing to do, which costs
  # one directory walk.
  #
  # The job is inserted straight into `oban_jobs` because the application, and
  # with it Oban, is not running while migrations are. It runs as soon as the
  # app starts, as the user the app runs as, so the rewritten files keep their
  # owner. The worker is named as a string, not by its module, so this file
  # keeps compiling if the module is ever renamed. The guard makes the insert
  # safe to apply again, and never queues a second sweep beside a pending one.
  #
  # Re-running the sweep later (after restoring an old uploads backup, say) is
  # `bin/tymeslot eval 'Tymeslot.Release.strip_upload_metadata()'`.

  @worker "Tymeslot.Workers.UploadMetadataSweepWorker"
  @pending_states "('available', 'scheduled', 'executing', 'retryable', 'suspended')"

  def up do
    # excellent_migrations:safety-assured-for-next-line raw_sql_executed
    execute("""
    INSERT INTO oban_jobs (state, queue, worker, args, max_attempts)
    SELECT 'available', 'media_processing', '#{@worker}', '{}'::jsonb, 3
    WHERE NOT EXISTS (
      SELECT 1 FROM oban_jobs
      WHERE worker = '#{@worker}' AND state IN #{@pending_states}
    )
    """)
  end

  # Withdraws the job if it has not started yet; a sweep already run cannot be
  # undone, and needs no undoing.
  def down do
    # excellent_migrations:safety-assured-for-next-line raw_sql_executed
    execute("""
    DELETE FROM oban_jobs
    WHERE worker = '#{@worker}' AND state IN ('available', 'scheduled', 'retryable')
    """)
  end
end
