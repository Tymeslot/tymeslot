defmodule TymeslotWeb.Helpers.UploadConstraintsTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :utils

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

    test "every extension is lowercase and dot-prefixed" do
      extensions =
        Enum.flat_map([:avatar, :image, :video], &UploadConstraints.allowed_extensions/1)

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
  end
end
