defmodule TymeslotWeb.Themes.Shared.Customization.VideoTest do
  use ExUnit.Case, async: true

  @moduletag :themes

  alias TymeslotWeb.Themes.Shared.Customization.Video

  describe "render_upload_video_sources/1" do
    test "generates responsive source tags with original as fallback" do
      html = Video.render_upload_video_sources("videos/abc123.mp4")

      assert html =~ ~s(src="/uploads/videos/abc123-desktop.webm")
      assert html =~ ~s(type="video/webm")
      assert html =~ "media=\"(min-width: 1024px)\""

      assert html =~ ~s(src="/uploads/videos/abc123-desktop.mp4")

      assert html =~ ~s(src="/uploads/videos/abc123-mobile.mp4")
      assert html =~ "media=\"(max-width: 768px)\""

      assert html =~ ~s(src="/uploads/videos/abc123-low.mp4")
      assert html =~ "media=\"(max-width: 480px)\""

      assert html =~ ~s(src="/uploads/videos/abc123.mp4")
    end

    test "original fallback uses the exact upload path, not -original suffix" do
      html = Video.render_upload_video_sources("videos/my-file.mp4")

      refute html =~ "-original.mp4"
      assert html =~ ~s(src="/uploads/videos/my-file.mp4")
    end

    test "handles filenames with multiple dots" do
      html = Video.render_upload_video_sources("videos/my.video.file.mp4")

      assert html =~ ~s(src="/uploads/videos/my.video.file-desktop.webm")
      assert html =~ ~s(src="/uploads/videos/my.video.file.mp4")
    end
  end
end
