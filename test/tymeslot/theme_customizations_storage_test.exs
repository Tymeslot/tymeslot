defmodule Tymeslot.ThemeCustomizationsStorageTest do
  use Tymeslot.DataCase, async: false
  @moduletag :utils

  alias Tymeslot.ThemeCustomizations.Storage

  setup do
    upload_root =
      Path.join(System.tmp_dir!(), "tymeslot_uploads_#{System.unique_integer([:positive])}")

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

    test "ensure_directory_exists/1 returns error tuple on permission denied" do
      # Create a read-only parent directory so mkdir_p inside it fails with :eacces
      parent = Path.join(System.tmp_dir!(), "tymeslot_readonly_#{:rand.uniform(100_000)}")
      File.mkdir_p!(parent)
      File.chmod!(parent, 0o444)

      try do
        child = Path.join(parent, "subdir")
        assert {:error, :eacces} = Storage.ensure_directory_exists(child)
      after
        File.chmod!(parent, 0o755)
        File.rm_rf!(parent)
      end
    end

    test "store_background_image/3 returns error tuple when directory creation fails" do
      # Point upload dir at a read-only location so ensure_directory_exists fails
      readonly = Path.join(System.tmp_dir!(), "tymeslot_ro_#{:rand.uniform(100_000)}")
      File.mkdir_p!(readonly)
      File.chmod!(readonly, 0o444)

      original_dir = Application.get_env(:tymeslot, :upload_directory)
      Application.put_env(:tymeslot, :upload_directory, readonly)

      temp_file = Path.join(System.tmp_dir!(), "test_img_#{:rand.uniform(100_000)}.jpg")
      # GIF magic bytes so MediaValidator accepts it
      File.write!(temp_file, "GIF89a" <> "data")

      try do
        result = Storage.store_background_image(1, "1", %{path: temp_file, filename: "bg.jpg"})
        assert {:error, :eacces} = result
      after
        Application.put_env(:tymeslot, :upload_directory, original_dir)
        File.chmod!(readonly, 0o755)
        File.rm_rf!(readonly)
        File.rm(temp_file)
      end
    end

    test "store_background_image/3 returns error for non-existent temp file" do
      result =
        Storage.store_background_image(1, "1", %{
          path: "/nonexistent/temp/file.jpg",
          filename: "test.jpg"
        })

      assert result == {:error, :invalid_image_format}
    end

    test "store_background_image/3 stores file successfully" do
      temp_dir = System.tmp_dir!()
      temp_file = Path.join(temp_dir, "test_image_#{:rand.uniform(100_000)}.jpg")
      # GIF magic bytes: GIF89a
      File.write!(temp_file, "GIF89a" <> "fake image data")

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
      # MP4 magic bytes: 00 00 00 18 66 74 79 70 69 73 6F 6D
      File.write!(temp_file, <<0x00, 0x00, 0x00, 0x18, "ftypisom", "fake video data">>)

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
