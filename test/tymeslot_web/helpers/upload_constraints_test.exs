defmodule TymeslotWeb.Helpers.UploadConstraintsTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :utils

  alias Tymeslot.Profiles.Avatars
  alias TymeslotWeb.Helpers.UploadConstraints

  describe "allowed_extensions/1" do
    test "avatars accept the animated and still image formats" do
      assert UploadConstraints.allowed_extensions(:avatar) ==
               [".jpg", ".jpeg", ".png", ".gif", ".webp"]
    end

    test "background images accept still formats only" do
      assert UploadConstraints.allowed_extensions(:image) == [".jpg", ".jpeg", ".png", ".webp"]
    end

    test "background videos accept mp4" do
      assert ".mp4" in UploadConstraints.allowed_extensions(:video)
    end

    test "captions accept WebVTT only" do
      assert UploadConstraints.allowed_extensions(:captions) == [".vtt"]
    end

    # Plug.Static and LiveView's `allow_upload/3` both type a file by MIME;
    # a <track> plays only a file served as text/vtt.
    test "WebVTT is known as text/vtt" do
      assert MIME.from_path("captions.vtt") == "text/vtt"
    end

    test "every extension is lowercase and dot-prefixed" do
      extensions =
        Enum.flat_map(
          [:avatar, :image, :video, :captions],
          &UploadConstraints.allowed_extensions/1
        )

      assert extensions != []
      assert Enum.reject(extensions, &(&1 == String.downcase(&1))) == []
      assert Enum.reject(extensions, &String.starts_with?(&1, ".")) == []
    end
  end

  describe "max_file_size/1" do
    test "allows progressively larger files for heavier media" do
      avatar = UploadConstraints.max_file_size(:avatar)
      image = UploadConstraints.max_file_size(:image)
      video = UploadConstraints.max_file_size(:video)

      assert avatar < image
      assert image < video
    end

    test "allows captions far less than an image, and states them in no megabyte figure" do
      assert UploadConstraints.max_file_size(:captions) == 200_000
      assert UploadConstraints.max_file_size(:captions) < UploadConstraints.max_file_size(:image)

      # Through a list, as the type checker already refuses the literal call.
      for kind <- [:captions] do
        assert_raise FunctionClauseError, fn -> UploadConstraints.max_file_size_mb(kind) end
      end
    end
  end

  describe "avatar upload path drift guard" do
    test "Avatars mirrors UploadConstraints' avatar limits rather than a second copy" do
      assert Avatars.accepted_extensions() == UploadConstraints.allowed_extensions(:avatar)
      assert Avatars.max_file_size() == UploadConstraints.max_file_size(:avatar)
    end
  end
end
