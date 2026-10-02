defmodule Tymeslot.Workers.UploadMetadataSweepWorkerTest do
  # The worker sweeps the configured upload directory, which each test points
  # at its own directory: application config is global, so not async.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :security
  @moduletag :workers
  @moduletag :tmp_dir

  alias Tymeslot.Test.MediaFixtures
  alias Tymeslot.Workers.UploadMetadataSweepWorker

  setup %{tmp_dir: upload_dir} do
    previous = Application.get_env(:tymeslot, :upload_directory)
    Application.put_env(:tymeslot, :upload_directory, upload_dir)
    on_exit(fn -> Application.put_env(:tymeslot, :upload_directory, previous) end)
    :ok
  end

  test "strips the metadata from images and videos in the upload directory", %{
    tmp_dir: upload_dir
  } do
    avatar = copy_fixture!(upload_dir, "avatars/7/7_avatar_1.jpg", "gps_portrait.jpg")
    video = copy_fixture!(upload_dir, "themes/7/1/videos/clip.mp4", "gps.mp4")

    assert :ok = perform_job(UploadMetadataSweepWorker, %{})

    assert MediaFixtures.image_metadata_fields(File.read!(avatar)) == []
    refute File.read!(video) =~ "location.ISO6709"
  end

  @tag :capture_log
  test "completes when a file cannot be processed, leaving it as it was", %{
    tmp_dir: upload_dir
  } do
    broken = Path.join(upload_dir, "avatars/8/8_avatar_1.jpg")
    File.mkdir_p!(Path.dirname(broken))
    File.write!(broken, "not an image")
    avatar = copy_fixture!(upload_dir, "avatars/7/7_avatar_1.jpg", "gps_portrait.jpg")

    assert :ok = perform_job(UploadMetadataSweepWorker, %{})

    assert File.read!(broken) == "not an image"
    assert MediaFixtures.image_metadata_fields(File.read!(avatar)) == []
  end

  test "queues no second sweep while one is pending" do
    assert {:ok, %Oban.Job{conflict?: false}} =
             Oban.insert(UploadMetadataSweepWorker.new(%{}))

    assert {:ok, %Oban.Job{conflict?: true}} =
             Oban.insert(UploadMetadataSweepWorker.new(%{}))
  end

  defp copy_fixture!(upload_dir, relative, fixture) do
    path = Path.join(upload_dir, relative)
    File.mkdir_p!(Path.dirname(path))
    File.cp!(MediaFixtures.path(fixture), path)
    path
  end
end
