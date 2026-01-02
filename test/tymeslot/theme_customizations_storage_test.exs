defmodule Tymeslot.ThemeCustomizationsStorageTest do
  use Tymeslot.DataCase, async: true

  alias Tymeslot.ThemeCustomizations.Storage

  setup do
    upload_root = Path.join(System.tmp_dir!(), "tymeslot_uploads_#{System.unique_integer([:positive])}")
    original_root = Application.get_env(:tymeslot, :upload_directory)

    Application.put_env(:tymeslot, :upload_directory, upload_root)

    on_exit(fn ->
      Application.put_env(:tymeslot, :upload_directory, original_root)
      File.rm_rf(upload_root)
    end)

    %{upload_root: upload_root}
  end

  describe "Storage module" do
    test "build_theme_file_path/1 creates full path", %{upload_root: upload_root} do
      relative_path = "themes/1/images/background.jpg"
      full_path = Storage.build_theme_file_path(relative_path)

      assert full_path =~ "themes/1/images/background.jpg"
      assert String.starts_with?(full_path, Storage.get_upload_base_directory())
      assert String.starts_with?(full_path, upload_root)
    end

    test "get_upload_base_directory/0 returns configured directory", %{upload_root: upload_root} do
      base_dir = Storage.get_upload_base_directory()

      assert is_binary(base_dir)
      assert base_dir == upload_root
    end

    test "get_theme_upload_directory/3 creates correct path structure" do
      path = Storage.get_theme_upload_directory(123, "1", "images")

      assert path =~ "themes/123/1/images"
    end

    test "get_theme_upload_directory/3 for videos" do
      path = Storage.get_theme_upload_directory(456, "2", "videos")

      assert path =~ "themes/456/2/videos"
    end

    test "ensure_directory_exists/1 creates directory" do
      test_dir = Path.join([System.tmp_dir!(), "tymeslot_test_#{:rand.uniform(100_000)}"])

      try do
        assert Storage.ensure_directory_exists(test_dir) == :ok
        assert File.dir?(test_dir)
      after
        File.rm_rf!(test_dir)
      end
    end

    test "store_background_image/3 returns error for non-existent temp file" do
      result =
        Storage.store_background_image(1, "1", %{
          path: "/nonexistent/temp/file.jpg",
          filename: "test.jpg"
        })

      assert result == {:error, :temp_file_not_found}
    end

    test "store_background_image/3 stores file successfully" do
      temp_dir = System.tmp_dir!()
      temp_file = Path.join(temp_dir, "test_image_#{:rand.uniform(100_000)}.jpg")
      File.write!(temp_file, "fake image data")

      try do
        assert {:ok, stored_path} =
                 Storage.store_background_image(1, "1", %{path: temp_file, filename: "test.jpg"})

        assert stored_path =~ "themes/1/1/images"
        full_path = Storage.build_theme_file_path(stored_path)
        assert File.exists?(full_path)
        File.rm!(full_path)
      after
        File.rm(temp_file)
      end
    end

    test "store_background_video/3 stores file" do
      temp_dir = System.tmp_dir!()
      temp_file = Path.join(temp_dir, "test_video_#{:rand.uniform(100_000)}.mp4")
      File.write!(temp_file, "fake video data")

      try do
        assert {:ok, stored_path} =
                 Storage.store_background_video(1, "1", %{path: temp_file, filename: "test.mp4"})

        assert stored_path =~ "themes/1/1/videos"
        full_path = Storage.build_theme_file_path(stored_path)
        assert File.exists?(full_path)
        File.rm!(full_path)
      after
        File.rm(temp_file)
      end
    end
  end
end
