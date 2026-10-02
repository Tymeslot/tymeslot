defmodule Tymeslot.Migrations.EnqueueUploadMetadataSweepTest do
  @moduledoc """
  Covers `20261002073024_enqueue_upload_metadata_sweep`, which queues the
  one-off sweep of metadata from files uploaded before uploads were stripped
  as they are stored, so an upgraded install is cleaned on its first boot.

  Driven from `priv` through `MigrationRunner`, inside the sandbox: the
  migration only inserts and deletes an `oban_jobs` row, so it is rolled back
  with the test. The job the real migration committed to the test database is
  cleared by `SuiteConfig.discard_committed_jobs!/0` before the suite starts,
  so every test here begins with none.
  """

  # The upload directory is application config, which the chain test points
  # at its own directory.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :database
  @moduletag :migrations
  @moduletag :security

  alias Tymeslot.Repo
  alias Tymeslot.Test.MediaFixtures
  alias Tymeslot.Test.MigrationRunner
  alias Tymeslot.Workers.UploadMetadataSweepWorker

  @version 20_261_002_073_024

  test "queues the sweep on the media processing queue" do
    MigrationRunner.rerun!(@version)

    assert [%Oban.Job{queue: "media_processing", args: %{}, max_attempts: 3}] =
             all_enqueued(worker: UploadMetadataSweepWorker)
  end

  test "does not queue a second sweep beside a pending one" do
    MigrationRunner.rerun!(@version)
    MigrationRunner.replay!(@version)

    assert [_job] = all_enqueued(worker: UploadMetadataSweepWorker)
  end

  test "rolling back withdraws a sweep that has not started" do
    MigrationRunner.rerun!(@version)
    MigrationRunner.down!(@version)

    assert all_enqueued(worker: UploadMetadataSweepWorker) == []
  end

  @tag :tmp_dir
  test "the queued job strips files uploaded before the upgrade", %{tmp_dir: upload_dir} do
    previous = Application.get_env(:tymeslot, :upload_directory)
    Application.put_env(:tymeslot, :upload_directory, upload_dir)
    on_exit(fn -> Application.put_env(:tymeslot, :upload_directory, previous) end)

    avatar = Path.join(upload_dir, "avatars/7/7_avatar_1.jpg")
    File.mkdir_p!(Path.dirname(avatar))
    File.cp!(MediaFixtures.path("gps_portrait.jpg"), avatar)
    assert MediaFixtures.image_metadata_fields(File.read!(avatar)) != []

    MigrationRunner.rerun!(@version)

    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :media_processing)
    assert MediaFixtures.image_metadata_fields(File.read!(avatar)) == []

    assert [%Oban.Job{state: "completed"}] =
             Repo.all(from j in Oban.Job, where: j.worker == ^inspect(UploadMetadataSweepWorker))
  end
end
