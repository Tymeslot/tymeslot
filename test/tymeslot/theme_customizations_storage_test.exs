defmodule Tymeslot.ThemeCustomizationsStorageTest do
  use Tymeslot.DataCase, async: false
  @moduletag :utils

  alias Tymeslot.Media.Uploads
  alias Tymeslot.Test.MediaFixtures
  alias Tymeslot.Test.UploadRoot
  alias Tymeslot.ThemeCustomizations.Storage
  alias Tymeslot.ThemeCustomizations.Validation

  setup do
    UploadRoot.isolate("tymeslot_uploads")
    :ok
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
    test "store_asset/4 returns error tuple when directory creation fails" do
      # Point upload dir at a read-only location so the store cannot create its directory
      readonly = Path.join(System.tmp_dir!(), "tymeslot_ro_#{:rand.uniform(100_000)}")
      File.mkdir_p!(readonly)
      File.chmod!(readonly, 0o444)

      UploadRoot.point_at(readonly)

      on_exit(fn ->
        File.chmod!(readonly, 0o755)
        File.rm_rf!(readonly)
      end)

      temp_file = MediaFixtures.temp_copy!("gps.webp")

      assert {:error, :eacces} =
               Storage.store_asset(:image, 1, "1", %{path: temp_file, filename: "bg.webp"})
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

      assert stored_path =~ ~r|\Athemes/1/1/images/[0-9a-f-]{36}\.png\z|
      assert File.exists?(UploadRoot.path(stored_path))
    end

    test "store_asset/4 stores a video under the theme's videos directory" do
      assert {:ok, stored_path} =
               Storage.store_asset(:video, 1, "2", %{path: video_file(), filename: "test.mp4"})

      assert stored_path =~ ~r|\Athemes/1/2/videos/[0-9a-f-]{36}\.mp4\z|
      assert File.exists?(UploadRoot.path(stored_path))
    end

    test "store_asset/4 gives two uploads of the same name paths of their own" do
      # Otherwise the second upload overwrites a file a setting still names,
      # and deleting either path would delete both.
      upload = fn -> %{path: image_file(), filename: "bg.png"} end
      {:ok, first} = Storage.store_asset(:image, 1, "1", upload.())
      {:ok, second} = Storage.store_asset(:image, 1, "1", upload.())

      assert first != second
      assert File.exists?(UploadRoot.path(first))
      assert File.exists?(UploadRoot.path(second))
    end

    # The media URL is built through `Validation.sanitize_path/1`; a stored
    # name it would rewrite is served under a name no file has, and 404s.
    for filename <- ["../photos/bg.png", "photo (1).png", "a..b.png", "café.png"] do
      test "store_asset/4 stores #{inspect(filename)} under a server-chosen name its URL keeps" do
        {:ok, stored_path} =
          Storage.store_asset(:image, 1, "1", %{path: image_file(), filename: unquote(filename)})

        assert Path.dirname(stored_path) == "themes/1/1/images"
        assert Path.basename(stored_path) =~ ~r/\A[0-9a-f-]{36}\.png\z/
        assert Validation.sanitize_path(stored_path) == stored_path
        assert File.exists?(UploadRoot.path(stored_path))
      end
    end

    test "store_asset/4 stores an image without its EXIF location" do
      assert {:ok, stored_path} =
               Storage.store_asset(:image, 1, "1", %{
                 path: MediaFixtures.temp_copy!("gps.webp"),
                 filename: "bg.webp"
               })

      contents = stored_path |> UploadRoot.path() |> File.read!()
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

      stored = stored_path |> UploadRoot.path() |> File.read!()
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

    test "store_asset/4 for a video names a WebM sent as .mp4 after what it is" do
      temp_file = MediaFixtures.temp_copy!("gps.webm")

      assert {:ok, stored_path} =
               Storage.store_asset(:video, 1, "1", %{path: temp_file, filename: "clip.mp4"})

      assert Path.basename(stored_path) =~ ~r/\A[0-9a-f-]{36}\.webm\z/
      assert File.exists?(UploadRoot.path(stored_path))
    end

    test "store_asset/4 for a video refuses junk whose first byte is the MPEG-TS sync byte" do
      temp_file = Path.join(System.tmp_dir!(), "test_video_#{System.unique_integer([:positive])}")
      File.write!(temp_file, <<0x47>> <> :binary.copy(<<0xFF>>, 1_000))
      on_exit(fn -> File.rm(temp_file) end)

      assert {:error, :invalid_video_format} =
               Storage.store_asset(:video, 1, "1", %{path: temp_file, filename: "clip.mp4"})
    end

    test "store_asset/4 for an image names a PNG sent as .jpg after what it is" do
      temp_file = MediaFixtures.temp_copy!("gps.png")

      assert {:ok, stored_path} =
               Storage.store_asset(:image, 1, "1", %{path: temp_file, filename: "bg.jpg"})

      assert Path.basename(stored_path) =~ ~r/\A[0-9a-f-]{36}\.png\z/
      stored = stored_path |> UploadRoot.path() |> File.read!()
      assert <<137, 80, 78, 71, _rest::binary>> = stored
      assert MediaFixtures.image_metadata_fields(stored) == []
    end

    test "store_asset/4 for an image refuses an animated GIF sent under an accepted name" do
      temp_file = MediaFixtures.temp_copy!("animated.gif")

      assert {:error, :invalid_image_format} =
               Storage.store_asset(:image, 1, "1", %{path: temp_file, filename: "bg.png"})
    end

    # The code default, "uploads", is relative to the working directory. The
    # row stores the returned path relative to the root, so the file must be
    # there, not under the root twice.
    @tag :tmp_dir
    test "store_asset/4 for a video stores under a relative upload root at the path it returns",
         %{tmp_dir: tmp_dir} do
      UploadRoot.point_at(Path.relative_to_cwd(tmp_dir))
      temp_file = MediaFixtures.temp_copy!("gps.mp4")

      assert {:ok, "themes/1/1/videos/" <> _name = stored_path} =
               Storage.store_asset(:video, 1, "1", %{path: temp_file, filename: "clip.mp4"})

      assert File.exists?(Path.join(tmp_dir, stored_path))
      refute File.exists?(Path.join([tmp_dir, Path.relative_to_cwd(tmp_dir), stored_path]))
    end

    @tag :tmp_dir
    test "store_asset/4 for an image stores under a relative upload root at the path it returns",
         %{tmp_dir: tmp_dir} do
      UploadRoot.point_at(Path.relative_to_cwd(tmp_dir))
      temp_file = MediaFixtures.temp_copy!("gps.webp")

      assert {:ok, "themes/1/1/images/" <> _name = stored_path} =
               Storage.store_asset(:image, 1, "1", %{path: temp_file, filename: "bg.webp"})

      assert File.exists?(Path.join(tmp_dir, stored_path))
      refute File.exists?(Path.join([tmp_dir, Path.relative_to_cwd(tmp_dir), stored_path]))
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

      assert stored_path =~ ~r|\Athemes/1/1/captions/[0-9a-f-]{36}\.vtt\z|
    end

    test "is the one the content is, whatever the client named the file" do
      for filename <- ["bg.vtt", "bg", "BG.JPG"] do
        assert {:ok, stored_path} =
                 Storage.store_asset(:image, 1, "1", %{path: image_file(), filename: filename})

        assert Path.extname(stored_path) == ".png", filename
      end
    end

    test "refuses content of a format its kind does not take, under any name" do
      assert Storage.store_asset(:image, 1, "1", %{path: gif_file(), filename: "bg.png"}) ==
               {:error, :invalid_image_format}

      assert Storage.store_asset(:video, 1, "1", %{path: mp4_file(), filename: "clip.mp4"}) ==
               {:error, :invalid_video_format}

      assert uploaded_files() == []
    end
  end

  defp uploaded_files do
    [Uploads.root(), "**", "*"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
  end
end
