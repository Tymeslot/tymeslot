defmodule Tymeslot.Workers.VideoTranscoderTest do
  use Tymeslot.DataCase, async: false

  @moduletag :workers

  use Oban.Testing, repo: Tymeslot.Repo
  import Mox
  import Tymeslot.Factory

  alias Tymeslot.DatabaseSchemas.ThemeCustomizationSchema
  alias Tymeslot.Media.Transcoder
  alias Tymeslot.Repo
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
    test "sets status to failed when a variant transcode errors" do
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
      assert updated.video_processing == "failed"
    end
  end

  describe "perform/1 - transcoding disabled" do
    setup do
      Application.put_env(:tymeslot, :video_transcoding_enabled, false)
      on_exit(fn -> Application.put_env(:tymeslot, :video_transcoding_enabled, true) end)
    end

    test "cancels job when video_transcoding_enabled is false" do
      theme_customization = insert_theme_customization()

      assert {:cancel, "transcoding disabled"} =
               perform_job(VideoTranscoder, %{
                 "theme_customization_id" => theme_customization.id,
                 "video_path" => "uploads/test-video.mp4"
               })
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
  end
end
