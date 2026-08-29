defmodule Tymeslot.Workers.VideoTranscoderTest do
  use Tymeslot.DataCase, async: false

  @moduletag :workers

  use Oban.Testing, repo: Tymeslot.Repo
  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Media.Transcoder
  alias Tymeslot.Repo
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationQueries
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema
  alias Tymeslot.Workers.VideoTranscoder

  setup :verify_on_exit!

  defp insert_theme_customization do
    profile = insert(:profile)
    insert(:theme_customization, profile: profile)
  end

  defp stub_all_variants_success do
    variant_count = length(Transcoder.variant_definitions())

    expect(Tymeslot.Media.TranscoderMock, :available?, fn -> true end)

    expect(Tymeslot.Media.TranscoderMock, :transcode, variant_count, fn _src, _out, _opts ->
      :ok
    end)
  end

  describe "perform/1 - successful transcoding" do
    test "transcodes all variants and updates status to completed" do
      theme_customization = insert_theme_customization()

      stub_all_variants_success()

      assert :ok =
               perform_job(VideoTranscoder, %{
                 "theme_customization_id" => theme_customization.id,
                 "video_path" => "uploads/test-video.mp4"
               })

      updated = Repo.get!(ThemeCustomizationSchema, theme_customization.id)
      assert updated.video_processing == "completed"
    end
  end

  describe "perform/1 - ffmpeg not available" do
    test "sets status to failed and cancels when ffmpeg is unavailable" do
      theme_customization = insert_theme_customization()

      expect(Tymeslot.Media.TranscoderMock, :available?, fn -> false end)

      assert {:cancel, "ffmpeg not available"} =
               perform_job(VideoTranscoder, %{
                 "theme_customization_id" => theme_customization.id,
                 "video_path" => "uploads/test-video.mp4"
               })

      updated = Repo.get!(ThemeCustomizationSchema, theme_customization.id)
      assert updated.video_processing == "failed"
    end
  end

  describe "perform/1 - transcoding failure" do
    test "does not set status to failed on non-final attempt" do
      theme_customization = insert_theme_customization()

      expect(Tymeslot.Media.TranscoderMock, :available?, fn -> true end)

      expect(Tymeslot.Media.TranscoderMock, :transcode, fn _src, _out, _opts ->
        {:error, "ffmpeg exited with status 1"}
      end)

      assert {:error, _reason} =
               perform_job(VideoTranscoder, %{
                 "theme_customization_id" => theme_customization.id,
                 "video_path" => "uploads/test-video.mp4"
               })

      updated = Repo.get!(ThemeCustomizationSchema, theme_customization.id)
      refute updated.video_processing == "failed"
    end

    test "sets status to failed on final attempt" do
      theme_customization = insert_theme_customization()

      expect(Tymeslot.Media.TranscoderMock, :available?, fn -> true end)

      expect(Tymeslot.Media.TranscoderMock, :transcode, fn _src, _out, _opts ->
        {:error, "ffmpeg exited with status 1"}
      end)

      assert {:error, _reason} =
               perform_job(
                 VideoTranscoder,
                 %{
                   "theme_customization_id" => theme_customization.id,
                   "video_path" => "uploads/test-video.mp4"
                 },
                 attempt: 3
               )

      updated = Repo.get!(ThemeCustomizationSchema, theme_customization.id)
      assert updated.video_processing == "failed"
    end
  end

  describe "perform/1 - source removed" do
    test "cancels without retrying when the source video is gone" do
      theme_customization = insert_theme_customization()

      expect(Tymeslot.Media.TranscoderMock, :available?, fn -> true end)

      expect(Tymeslot.Media.TranscoderMock, :transcode, fn _src, _out, _opts ->
        {:error, :source_missing}
      end)

      # {:cancel, _} stops the job outright. An {:error, _} here would spend all
      # three attempts against a file that no longer exists and end in a
      # permanent-failure admin alert.
      assert {:cancel, "Video source no longer present"} =
               perform_job(VideoTranscoder, %{
                 "theme_customization_id" => theme_customization.id,
                 "video_path" => "uploads/test-video.mp4"
               })
    end

    test "leaves the processing status alone for a replacement upload to own" do
      theme_customization = insert_theme_customization()

      # What a replacement upload writes before enqueuing its own transcode.
      :ok =
        ThemeCustomizationQueries.update_video_processing_status(
          theme_customization.id,
          "pending"
        )

      expect(Tymeslot.Media.TranscoderMock, :available?, fn -> true end)

      expect(Tymeslot.Media.TranscoderMock, :transcode, fn _src, _out, _opts ->
        {:error, :source_missing}
      end)

      assert {:cancel, _reason} =
               perform_job(
                 VideoTranscoder,
                 %{
                   "theme_customization_id" => theme_customization.id,
                   "video_path" => "uploads/test-video.mp4"
                 },
                 attempt: 3
               )

      # Marking this "failed" would report the abandoned video's fate against
      # the replacement that is still being processed.
      updated = Repo.get!(ThemeCustomizationSchema, theme_customization.id)
      assert updated.video_processing == "pending"
    end
  end

  describe "perform/1 - path traversal" do
    test "rejects video_path containing directory traversal and sets status to failed" do
      theme_customization = insert_theme_customization()

      expect(Tymeslot.Media.TranscoderMock, :available?, fn -> true end)

      assert {:error, "Invalid video path"} =
               perform_job(VideoTranscoder, %{
                 "theme_customization_id" => theme_customization.id,
                 "video_path" => "../../etc/passwd"
               })

      updated = Repo.get!(ThemeCustomizationSchema, theme_customization.id)
      assert updated.video_processing == "failed"
    end
  end

  describe "enqueue/2" do
    test "creates a job in the media_processing queue" do
      theme_customization = insert_theme_customization()

      assert {:ok, _job} = VideoTranscoder.enqueue(theme_customization.id, "uploads/video.mp4")

      assert_enqueued(
        worker: VideoTranscoder,
        args: %{
          "theme_customization_id" => theme_customization.id,
          "video_path" => "uploads/video.mp4"
        }
      )
    end

    test "a replacement arriving mid-run snoozes so the next run transcodes it" do
      theme_customization = insert_theme_customization()

      {:ok, job} = VideoTranscoder.enqueue(theme_customization.id, "uploads/old.mp4")

      # A replacement upload cannot insert a job of its own while this one is
      # pending: uniqueness matches the row and only replaces its args, which
      # the running process never rereads. `job` is the stale in-memory struct
      # that process would still be holding.
      assert {:ok, %Oban.Job{conflict?: true}} =
               VideoTranscoder.enqueue(theme_customization.id, "uploads/new.mp4")

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
        | args: %{
            "theme_customization_id" => theme_customization.id,
            "video_path" => "uploads/old.mp4"
          },
          attempt: 1,
          attempted_at: DateTime.utc_now(),
          scheduled_at: DateTime.utc_now()
      }

      assert {:snooze, 1} = perform_job(job)

      # The status stays whatever the replacement upload set; this run must not
      # report the old video's fate against the new one.
      updated = Repo.get!(ThemeCustomizationSchema, theme_customization.id)
      assert updated.video_processing != "failed"
    end
  end
end
