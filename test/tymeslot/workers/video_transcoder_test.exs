defmodule Tymeslot.Workers.VideoTranscoderTest do
  @moduledoc """
  The transcoding worker records each video's processing state under its
  own asset field, so two videos of one theme are processed, retried and
  reported apart, and only while the field still holds the video the job
  transcodes.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :workers
  @moduletag :themes

  use Oban.Testing, repo: Tymeslot.Repo
  import Mox
  import Ecto.Query
  import Tymeslot.Factory

  alias Tymeslot.Media.Transcoder
  alias Tymeslot.Media.Uploads
  alias Tymeslot.Repo
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationQueries
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema
  alias Tymeslot.Workers.VideoTranscoder

  @field "background_video_path"

  setup :verify_on_exit!

  # The row a job reports to holds the video the job transcodes.
  defp insert_theme_customization(video_path \\ "uploads/test-video.mp4") do
    profile = insert(:profile)
    insert(:theme_customization, profile: profile, background_video_path: video_path)
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

  # What an upload into `field` writes: the new path, then its pending state.
  defp put_video!(customization, field, video_path) do
    {1, _rows} =
      Repo.update_all(
        from(c in ThemeCustomizationSchema,
          where: c.id == ^customization.id,
          update: [
            set: [
              settings:
                fragment(
                  "? || jsonb_build_object(?::text, ?::text)",
                  c.settings,
                  ^field,
                  ^video_path
                )
            ]
          ]
        ),
        []
      )

    {:ok, _pending} =
      ThemeCustomizationQueries.update_video_processing_status(customization.id, field, "pending")

    :ok
  end

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
      put_video!(customization, "host_video_path", "uploads/host.mp4")
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
      put_video!(customization, @field, "uploads/test-video.mp4")

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

  describe "timeout/1" do
    test "bounds the job, with room for every variant's own bound" do
      job = VideoTranscoder.new(%{theme_customization_id: 1, video_path: "uploads/v.mp4"})

      timeout = VideoTranscoder.timeout(job)

      assert is_integer(timeout)

      assert timeout >
               length(Transcoder.variant_definitions()) * Transcoder.max_variant_timeout()
    end

    test "ends the job before the Oban lifeline would run it a second time" do
      job = VideoTranscoder.new(%{theme_customization_id: 1, video_path: "uploads/v.mp4"})

      # `ObanRescue`'s longest legitimate job: the lifeline rescues after more.
      assert VideoTranscoder.timeout(job) <= :timer.hours(5)
    end
  end

  describe "perform/1 - a variant that times out" do
    test "marks the video failed on the first attempt, without a retry" do
      # A retry would run as long again, holding the one-at-a-time queue for
      # every other video.
      customization = insert_theme_customization()

      expect(Tymeslot.Media.TranscoderMock, :available?, fn -> true end)

      expect(Tymeslot.Media.TranscoderMock, :transcode, fn _src, _out, _opts ->
        {:error, :timeout}
      end)

      assert {:cancel, "Video encode timed out"} =
               perform_job(VideoTranscoder, args(customization, "uploads/test-video.mp4"),
                 attempt: 1
               )

      assert statuses(customization) == %{@field => "failed"}
    end
  end

  describe "perform/1 - path traversal" do
    test "cancels without retrying and records the field as failed" do
      customization = insert_theme_customization("../../etc/passwd")
      expect(Tymeslot.Media.TranscoderMock, :available?, fn -> true end)

      # The path cannot become acceptable on a later attempt.
      assert {:cancel, "Invalid video path"} =
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

    test "a replacement before the job starts takes over its args" do
      customization = insert_theme_customization()

      {:ok, job} = VideoTranscoder.enqueue(customization.id, @field, "uploads/old.mp4")

      assert {:ok, %Oban.Job{conflict?: true}} =
               VideoTranscoder.enqueue(customization.id, @field, "uploads/new.mp4")

      assert %{args: %{"video_path" => "uploads/new.mp4"}} = Repo.reload!(job)
    end
  end

  # A replacement uploaded while a job encodes gets a job of its own; the
  # running one, which never rereads its args, must settle nothing for it.
  describe "a replacement uploaded while a job executes" do
    setup do
      customization = insert_theme_customization("uploads/old.mp4")
      {:ok, old_job} = VideoTranscoder.enqueue(customization.id, @field, "uploads/old.mp4")

      Repo.update_all(from(j in Oban.Job, where: j.id == ^old_job.id), set: [state: "executing"])

      # What the replacement upload writes, then its own enqueue.
      put_video!(customization, @field, "uploads/new.mp4")
      {:ok, new_job} = VideoTranscoder.enqueue(customization.id, @field, "uploads/new.mp4")

      %{customization: customization, old_job: old_job, new_job: new_job}
    end

    test "is inserted as a second job", %{old_job: old_job, new_job: new_job} do
      refute new_job.conflict?
      refute new_job.id == old_job.id
      assert %{args: %{"video_path" => "uploads/old.mp4"}} = Repo.reload!(old_job)
    end

    test "the stale run cancels and removes its variants, and the new run completes",
         %{customization: customization} do
      old_variants = touch_variants("uploads/old.mp4")
      stub_all_variants_success()

      assert {:cancel, "Video replaced before its transcode finished"} =
               perform_job(VideoTranscoder, args(customization, "uploads/old.mp4"))

      refute Enum.any?(old_variants, &File.exists?/1)
      assert statuses(customization) == %{@field => "pending"}

      stub_all_variants_success()

      assert :ok = perform_job(VideoTranscoder, args(customization, "uploads/new.mp4"))

      updated = Repo.get!(ThemeCustomizationSchema, customization.id)

      assert {updated.settings[@field], updated.video_processing_status} ==
               {"uploads/new.mp4", %{@field => "completed"}}
    end

    test "the stale run timing out does not fail the replacement",
         %{customization: customization} do
      expect(Tymeslot.Media.TranscoderMock, :available?, fn -> true end)

      expect(Tymeslot.Media.TranscoderMock, :transcode, fn _src, _out, _opts ->
        {:error, :timeout}
      end)

      assert {:cancel, "Video encode timed out"} =
               perform_job(VideoTranscoder, args(customization, "uploads/old.mp4"))

      assert statuses(customization) == %{@field => "pending"}
    end

    test "the stale run failing its final attempt does not fail the replacement",
         %{customization: customization} do
      expect(Tymeslot.Media.TranscoderMock, :available?, fn -> true end)

      expect(Tymeslot.Media.TranscoderMock, :transcode, fn _src, _out, _opts ->
        {:error, "ffmpeg exited with status 1"}
      end)

      assert {:error, _reason} =
               perform_job(VideoTranscoder, args(customization, "uploads/old.mp4"), attempt: 3)

      assert statuses(customization) == %{@field => "pending"}
    end
  end

  defp touch_variants(video_path) do
    for variant <- Transcoder.derive_variant_paths(video_path) do
      path = Path.join(Uploads.root(), variant)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "variant")
      path
    end
  end
end
