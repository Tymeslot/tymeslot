defmodule TymeslotWeb.Helpers.ThemeUploadHelperTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :themes
  @moduletag :profiles

  import Mox

  alias Phoenix.LiveView.Socket
  alias TymeslotWeb.Helpers.ThemeUploadHelper

  setup :verify_on_exit!

  describe "process_background_video_upload/2 when ffmpeg is unavailable" do
    test "rejects the upload immediately with an honest ffmpeg message" do
      # ffmpeg is auto-detected at transcode time; when it is missing the
      # upload must fail up front rather than reporting success and silently
      # failing in the background worker.
      stub(Tymeslot.Media.TranscoderMock, :available?, fn -> false end)

      socket = %Socket{assigns: %{theme_id: "1"}}

      assert {:error, message} =
               ThemeUploadHelper.process_background_video_upload(socket, %{id: 1})

      assert message =~ "ffmpeg is not installed"
    end

    test "does not enqueue a transcoding job when ffmpeg is missing" do
      stub(Tymeslot.Media.TranscoderMock, :available?, fn -> false end)

      socket = %Socket{assigns: %{theme_id: "1"}}

      assert {:error, _message} =
               ThemeUploadHelper.process_background_video_upload(socket, %{id: 1})

      refute_enqueued(worker: Tymeslot.Workers.VideoTranscoder)
    end
  end
end
