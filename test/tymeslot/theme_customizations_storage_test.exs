defmodule Tymeslot.ThemeCustomizationsStorageTest do
  use Tymeslot.DataCase, async: false
  @moduletag :utils

  alias Tymeslot.Test.MediaFixtures
  alias Tymeslot.ThemeCustomizations.Storage
  alias Tymeslot.ThemeCustomizations.Validation

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

  # A real image and a real video, which the metadata strippers can read to
  # the end; a stored file has been through them.
  defp image_file, do: MediaFixtures.temp_copy!("gps.png")
  defp video_file, do: MediaFixtures.temp_copy!("gps.mp4")

  # GIF magic bytes, which MediaValidator accepts as an image, over content
  # no decoder can read.
  defp gif_file, do: temp_file("GIF89a" <> "fake image data")

  # PNG magic bytes: 89 50 4E 47 0D 0A 1A 0A
  defp png_file, do: temp_file(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, "fake image data">>)

  # MP4 magic bytes: 00 00 00 18 66 74 79 70 69 73 6F 6D
  defp mp4_file, do: temp_file(<<0x00, 0x00, 0x00, 0x18, "ftypisom", "fake video data">>)

  defp temp_file(contents) do
    path = Path.join(System.tmp_dir!(), "tymeslot_store_#{System.unique_integer([:positive])}")
    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    path
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

    test "store_asset/4 returns error tuple when directory creation fails" do
      # Point upload dir at a read-only location so ensure_directory_exists fails
      readonly = Path.join(System.tmp_dir!(), "tymeslot_ro_#{:rand.uniform(100_000)}")
      File.mkdir_p!(readonly)
      File.chmod!(readonly, 0o444)

      original_dir = Application.get_env(:tymeslot, :upload_directory)
      Application.put_env(:tymeslot, :upload_directory, readonly)

      temp_file = MediaFixtures.temp_copy!("gps.webp")

      try do
        assert {:error, :eacces} =
                 Storage.store_asset(:image, 1, "1", %{path: temp_file, filename: "bg.webp"})
      after
        Application.put_env(:tymeslot, :upload_directory, original_dir)
        File.chmod!(readonly, 0o755)
        File.rm_rf!(readonly)
      end
    end

    test "store_asset/4 refuses a temp file that does not exist" do
      assert Storage.store_asset(:image, 1, "1", %{
               path: "/nonexistent/temp/file.jpg",
               filename: "test.jpg"
             }) == {:error, :invalid_image_format}
    end

    test "store_asset/4 refuses content that is not of the kind asked for" do
      assert Storage.store_asset(:video, 1, "1", %{path: png_file(), filename: "clip.mp4"}) ==
               {:error, :invalid_video_format}

      # A GIF's leading "G" is also the MPEG-TS sync byte, which once let a
      # GIF named `.mp4` through as a video.
      assert Storage.store_asset(:video, 1, "1", %{path: gif_file(), filename: "clip.mp4"}) ==
               {:error, :invalid_video_format}

      assert Storage.store_asset(:image, 1, "1", %{path: mp4_file(), filename: "bg.png"}) ==
               {:error, :invalid_image_format}
    end

    test "store_asset/4 stores an image under the theme's images directory" do
      assert {:ok, stored_path} =
               Storage.store_asset(:image, 1, "1", %{path: image_file(), filename: "test.png"})

      assert stored_path =~ ~r|\Athemes/1/1/images/[0-9a-f]{12}-test\.png\z|
      assert File.exists?(Storage.build_theme_file_path(stored_path))
    end

    test "store_asset/4 stores a video under the theme's videos directory" do
      assert {:ok, stored_path} =
               Storage.store_asset(:video, 1, "2", %{path: video_file(), filename: "test.mp4"})

      assert stored_path =~ ~r|\Athemes/1/2/videos/[0-9a-f]{12}-test\.mp4\z|
      assert File.exists?(Storage.build_theme_file_path(stored_path))
    end

    test "store_asset/4 gives two uploads of the same name paths of their own" do
      # Otherwise the second upload overwrites a file a setting still names,
      # and deleting either path would delete both.
      upload = fn -> %{path: image_file(), filename: "bg.png"} end
      {:ok, first} = Storage.store_asset(:image, 1, "1", upload.())
      {:ok, second} = Storage.store_asset(:image, 1, "1", upload.())

      assert first != second
      assert File.exists?(Storage.build_theme_file_path(first))
      assert File.exists?(Storage.build_theme_file_path(second))
    end

    test "store_asset/4 keeps the prefix when the client name carries a directory" do
      {:ok, stored_path} =
        Storage.store_asset(:image, 1, "1", %{path: image_file(), filename: "../photos/bg.png"})

      assert Path.basename(stored_path) =~ ~r|\A[0-9a-f]{12}-bg\.png\z|
      assert Path.dirname(stored_path) == "themes/1/1/images"
    end

    # The media URL is built through `Validation.sanitize_path/1`; a stored
    # name it would rewrite is served under a name no file has, and 404s.
    for {filename, stem} <- [
          {"photo (1).jpg", "photo__1_"},
          {"a..b.png", "a__b"},
          {"café.png", "caf__"}
        ] do
      test "store_asset/4 stores #{inspect(filename)} under a name its URL keeps" do
        {:ok, stored_path} =
          Storage.store_asset(:image, 1, "1", %{path: image_file(), filename: unquote(filename)})

        extension = Path.extname(unquote(filename))

        assert Path.basename(stored_path) =~
                 ~r/\A[0-9a-f]{12}-#{unquote(stem)}#{Regex.escape(extension)}\z/

        assert Validation.sanitize_path(stored_path) == stored_path

        assert File.exists?(Storage.build_theme_file_path(Validation.sanitize_path(stored_path)))
      end
    end

    test "store_asset/4 shortens a long client name to fit, keeping its extension" do
      # Uploads are served only with an allowed extension, so a name cut after the
      # prefix was added would store a file that can never be served.
      filename = String.duplicate("a", 246) <> ".png"

      {:ok, stored_path} =
        Storage.store_asset(:image, 1, "1", %{path: image_file(), filename: filename})

      stored_name = Path.basename(stored_path)

      assert stored_name =~ ~r|\A[0-9a-f]{12}-a+\.png\z|
      assert byte_size(stored_name) == 255
      assert File.exists?(Storage.build_theme_file_path(stored_path))
    end

    # The prefix is 13 bytes and the extension 4, so a stem of 238 bytes
    # exactly fills the 255-byte limit and 239 is the first one cut.
    for stem_bytes <- [238, 239] do
      test "store_asset/4 fits a #{stem_bytes}-byte stem into the limit" do
        filename = String.duplicate("a", unquote(stem_bytes)) <> ".png"

        {:ok, stored_path} =
          Storage.store_asset(:image, 1, "1", %{path: image_file(), filename: filename})

        stored_name = Path.basename(stored_path)

        assert stored_name =~ ~r|\A[0-9a-f]{12}-a{238}\.png\z|
        assert byte_size(stored_name) == 255
        assert File.exists?(Storage.build_theme_file_path(stored_path))
      end
    end

    test "store_asset/4 stores an image without its EXIF location" do
      assert {:ok, stored_path} =
               Storage.store_asset(:image, 1, "1", %{
                 path: MediaFixtures.temp_copy!("gps.webp"),
                 filename: "bg.webp"
               })

      contents = stored_path |> Storage.build_theme_file_path() |> File.read!()
      assert MediaFixtures.image_metadata_fields(contents) == []
      refute contents =~ "Model-X"
    end

    test "store_asset/4 refuses a file that only has image magic bytes" do
      assert Storage.store_asset(:image, 1, "1", %{path: gif_file(), filename: "bg.png"}) ==
               {:error, :invalid_image_format}

      assert uploaded_files() == []
    end

    test "store_asset/4 stores a video without its location" do
      assert {:ok, stored_path} =
               Storage.store_asset(:video, 1, "1", %{
                 path: MediaFixtures.temp_copy!("gps.mp4"),
                 filename: "test.mp4"
               })

      stored = stored_path |> Storage.build_theme_file_path() |> File.read!()
      assert byte_size(stored) == byte_size(MediaFixtures.read!("gps.mp4"))
      refute stored =~ <<0xA9, "xyz">>
      refute stored =~ "location.ISO6709"
    end

    test "store_asset/4 refuses a video container whose metadata cannot be stripped" do
      # AVI passes the magic-byte check but is neither MP4 nor WebM.
      avi = temp_file("RIFF" <> <<100::little-32>> <> "AVI LIST")

      assert Storage.store_asset(:video, 1, "1", %{path: avi, filename: "clip.mp4"}) ==
               {:error, :invalid_video_format}

      assert uploaded_files() == []
    end
  end

  # `/uploads` types a file by its extension, and LiveView accepts an upload
  # on the client's type alone, so the stored extension never rests on the
  # client's name.
  describe "the stored extension" do
    test "is always .vtt for captions, whatever the client named the file" do
      vtt = temp_file("WEBVTT\n\n00:00.000 --> 00:02.000\nHello\n")

      assert {:ok, stored_path} =
               Storage.store_asset(:captions, 1, "1", %{path: vtt, filename: "intro.png"})

      assert stored_path =~ ~r|\Athemes/1/1/captions/[0-9a-f]{12}-intro\.vtt\z|
    end

    test "refuses an image or a video named with an extension its kind does not take" do
      assert Storage.store_asset(:image, 1, "1", %{path: gif_file(), filename: "bg.vtt"}) ==
               {:error, :invalid_image_format}

      assert Storage.store_asset(:image, 1, "1", %{path: gif_file(), filename: "bg"}) ==
               {:error, :invalid_image_format}

      assert Storage.store_asset(:video, 1, "1", %{path: mp4_file(), filename: "clip.png"}) ==
               {:error, :invalid_video_format}

      assert uploaded_files() == []
    end

    test "keeps an allowed extension, lower-cased" do
      assert {:ok, stored_path} =
               Storage.store_asset(:image, 1, "1", %{path: image_file(), filename: "BG.PNG"})

      assert stored_path =~ ~r|\Athemes/1/1/images/[0-9a-f]{12}-BG\.png\z|
    end
  end

  defp uploaded_files do
    [Storage.get_upload_base_directory(), "**", "*"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
  end
end
