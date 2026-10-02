defmodule Tymeslot.Workers.UploadMetadataSweepWorker do
  @moduledoc """
  Runs `Tymeslot.Media.UploadMetadataSweep` once in the background, stripping
  location, capture time and device metadata from the files uploaded before
  uploads were stripped as they are stored.

  The job is queued by the `enqueue_upload_metadata_sweep` migration, so an
  upgraded install runs it on its first boot after the upgrade and never
  again. It runs inside the app, as the user the app runs as, so rewritten
  files keep their owner.

  Files the sweep cannot process are logged one by one and do not fail the
  job: running it again would meet the same files. A crash part-way through
  is retried, which is safe because the sweep is idempotent. Re-running it by
  hand is `Tymeslot.Release.strip_upload_metadata/0`.
  """

  use Oban.Worker,
    queue: :media_processing,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  alias Tymeslot.Media.UploadMetadataSweep

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    _report = UploadMetadataSweep.run()
    :ok
  end
end
