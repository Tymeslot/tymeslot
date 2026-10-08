defmodule Tymeslot.Workers.VideoTranscoderTest do
  @moduledoc """
  The transcoding worker records each video's processing state under its
  own asset field, so two videos of one theme are processed, retried and
  reported apart.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :workers
  @moduletag :themes

  use Oban.Testing, repo: Tymeslot.Repo
  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Media.Transcoder
  alias Tymeslot.Repo
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationQueries
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema
  alias Tymeslot.Workers.VideoTranscoder

  @field "background_video_path"

  setup :verify_on_exit!

  defp insert_theme_customization do
    profile = insert(:profile)
    insert(:theme_customization, profile: profile)
  end

  defp args(customization, video_path, field \\ @field) do
    %{
      "theme_customization_id" => customization.id,
      "field" => field,
      "video_path" => video_path
    }
  end

  defp statuses(customization),
    do: Repo.get!(ThemeCustomizationSchema, customization.id).video_processing_status

  defp stub_all_variants_success do
    variant_count = length(Transcoder.variant_definitions())

    expect(Tymeslot.Media.TranscoderMock, :available?, fn -> true end)

    expect(Tymeslot.Media.TranscoderMock, :transcode, variant_count, fn _src, _out, _opts ->
      :ok
    end)
  end

  describe "perform/1 - successful transcoding" do
    test "transcodes all variants and records the field as completed" do
      customization = insert_theme_customization()
      stub_all_variants_success()

      assert :ok = perform_job(VideoTranscoder, args(customization, "uploads/test-video.mp4"))

      assert statuses(customization) == %{@field => "completed"}
    end

    test "records only its own field, leaving another video's state as it is" do
      customization = insert_theme_customization()

      {:ok, _pending} =
        ThemeCustomizationQueries.update_video_processing_status(
          customization.id,
          "host_video_path",
          "pending"
        )

      stub_all_variants_success()

      assert :ok = perform_job(VideoTranscoder, args(customization, "uploads/test-video.mp4"))

      assert statuses(customization) == %{
               @field => "completed",
               "host_video_path" => "pending"
             }
    end

    test "a job queued before videos were tracked per field reports under the background video" do
      customization = insert_theme_customization()
      stub_all_variants_success()

      assert :ok =
               perform_job(VideoTranscoder, %{
                 "theme_customization_id" => customization.id,
                 "video_path" => "uploads/test-video.mp4"
               })

      assert statuses(customization) == %{"background_video_path" => "completed"}
    end
  end

  describe "perform/1 - ffmpeg not available" do
    test "records the field as failed and cancels" do
      customization = insert_theme_customization()
      expect(Tymeslot.Media.TranscoderMock, :available?, fn -> false end)

      assert {:cancel, "ffmpeg not available"} =
               perform_job(VideoTranscoder, args(customization, "uploads/test-video.mp4"))

      assert statuses(customization) == %{@field => "failed"}
    end

    # A customisation deleted while its video waited has nowhere to record
    # the state: the job still ends as it would, without crashing.
    test "cancels as usual when the customisation was deleted meanwhile" do
      customization = insert_theme_customization()
      Repo.delete!(customization)
      expect(Tymeslot.Media.TranscoderMock, :available?, fn -> false end)

      assert {:cancel, "ffmpeg not available"} =
               perform_job(VideoTranscoder, args(customization, "uploads/test-video.mp4"))

      assert Repo.get(ThemeCustomizationSchema, customization.id) == nil
    end
  end

  describe "perform/1 - transcoding failure" do
    test "does not record a failure on a non-final attempt" do
      customization = insert_theme_customization()
      expect(Tymeslot.Media.TranscoderMock, :available?, fn -> true end)

      expect(Tymeslot.Media.TranscoderMock, :transcode, fn _src, _out, _opts ->
        {:error, "ffmpeg exited with status 1"}
      end)

      assert {:error, _reason} =
               perform_job(VideoTranscoder, args(customization, "uploads/test-video.mp4"))

      assert statuses(customization) == %{}
    end

    test "records the field as failed on the final attempt" do
      customization = insert_theme_customization()
      expect(Tymeslot.Media.TranscoderMock, :available?, fn -> true end)

      expect(Tymeslot.Media.TranscoderMock, :transcode, fn _src, _out, _opts ->
        {:error, "ffmpeg exited with status 1"}
      end)

      assert {:error, _reason} =
               perform_job(VideoTranscoder, args(customization, "uploads/test-video.mp4"),
                 attempt: 3
               )

      assert statuses(customization) == %{@field => "failed"}
    end
  end

  describe "perform/1 - source removed" do
    test "cancels without retrying when the source video is gone" do
      customization = insert_theme_customization()
      expect(Tymeslot.Media.TranscoderMock, :available?, fn -> true end)

      expect(Tymeslot.Media.TranscoderMock, :transcode, fn _src, _out, _opts ->
        {:error, :source_missing}
      end)

      # {:cancel, _} stops the job outright. An {:error, _} here would spend all
      # three attempts against a file that no longer exists and end in a
      # permanent-failure admin alert.
      assert {:cancel, "Video source no longer present"} =
               perform_job(VideoTranscoder, args(customization, "uploads/test-video.mp4"))
    end

    test "leaves the field's state alone for a replacement upload to own" do
      customization = insert_theme_customization()

      # What a replacement upload writes before enqueuing its own transcode.
      {:ok, _pending} =
        ThemeCustomizationQueries.update_video_processing_status(
          customization.id,
          @field,
          "pending"
        )

      expect(Tymeslot.Media.TranscoderMock, :available?, fn -> true end)

      expect(Tymeslot.Media.TranscoderMock, :transcode, fn _src, _out, _opts ->
        {:error, :source_missing}
      end)

      assert {:cancel, _reason} =
               perform_job(VideoTranscoder, args(customization, "uploads/test-video.mp4"),
                 attempt: 3
               )

      # Marking this "failed" would report the abandoned video's fate against
      # the replacement that is still being processed.
      assert statuses(customization) == %{@field => "pending"}
    end
  end

  describe "perform/1 - path traversal" do
    test "rejects a video_path containing directory traversal and records the field as failed" do
      customization = insert_theme_customization()
      expect(Tymeslot.Media.TranscoderMock, :available?, fn -> true end)

      assert {:error, "Invalid video path"} =
               perform_job(VideoTranscoder, args(customization, "../../etc/passwd"))

      assert statuses(customization) == %{@field => "failed"}
    end
  end

  describe "enqueue/3" do
    test "creates a job in the media_processing queue, carrying the field" do
      customization = insert_theme_customization()

      assert {:ok, _job} =
               VideoTranscoder.enqueue(
                 customization.id,
                 :background_video_path,
                 "uploads/video.mp4"
               )

      assert_enqueued(
        worker: VideoTranscoder,
        queue: :media_processing,
        args: args(customization, "uploads/video.mp4")
      )
    end

    test "two fields of one customisation are two jobs" do
      customization = insert_theme_customization()

      assert {:ok, %Oban.Job{conflict?: false}} =
               VideoTranscoder.enqueue(customization.id, "background_video_path", "uploads/a.mp4")

      assert {:ok, %Oban.Job{conflict?: false}} =
               VideoTranscoder.enqueue(customization.id, "host_video_path", "uploads/b.mp4")

      assert length(all_enqueued(worker: VideoTranscoder)) == 2
    end

    test "a replacement arriving mid-run snoozes so the next run transcodes it" do
      customization = insert_theme_customization()

      {:ok, job} = VideoTranscoder.enqueue(customization.id, @field, "uploads/old.mp4")

      # A replacement upload into the same field cannot insert a job of its
      # own while this one is pending: uniqueness matches the row and the
      # field, and only replaces the args, which the running process never
      # rereads. `job` is the stale in-memory struct that process would hold.
      assert {:ok, %Oban.Job{conflict?: true}} =
               VideoTranscoder.enqueue(customization.id, @field, "uploads/new.mp4")

      expect(Tymeslot.Media.TranscoderMock, :available?, fn -> true end)

      expect(Tymeslot.Media.TranscoderMock, :transcode, fn _src, _out, _opts ->
        {:error, :source_missing}
      end)

      # Cancelling here would take the replacement's args to the grave; the job
      # must come back and reread them instead. The fields below are what a
      # fetched, running job carries: string-keyed args and execution stamps,
      # which `Oban.insert`'s returned struct does not have.
      job = %{
        job
        | args: args(customization, "uploads/old.mp4"),
          attempt: 1,
          attempted_at: DateTime.utc_now(),
          scheduled_at: DateTime.utc_now()
      }

      assert {:snooze, 1} = perform_job(job)

      # The state stays whatever the replacement upload set; this run must not
      # report the old video's fate against the new one.
      refute statuses(customization)[@field] == "failed"
    end
  end
end
