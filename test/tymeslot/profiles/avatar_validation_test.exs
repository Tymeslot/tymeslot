defmodule Tymeslot.Profiles.AvatarValidationTest do
  use Tymeslot.DataCase, async: true

  @moduletag :profiles

  alias Tymeslot.Media.Uploads
  alias Tymeslot.Profiles
  alias Tymeslot.Repo
  alias Tymeslot.Test.MediaFixtures

  # consume_avatar_upload/4 wraps validation errors as {:ok, {:error, reason}}.

  defp upload_stub(path \\ "/tmp/test_upload"), do: %{path: path}
  defp entry(name, size \\ 1_000), do: %{client_name: name, client_size: size}

  describe "consume_avatar_upload/4 - file type validation" do
    test "accepts .jpg extension" do
      profile = insert(:profile)
      result = Profiles.consume_avatar_upload(profile, upload_stub(), entry("photo.jpg"), %{})

      # The extension passes, so the call runs on to the size check, which
      # fails because the stub path names no real file. A rejected extension
      # would surface :invalid_file_type instead.
      assert result == {:ok, {:error, :unreadable_file}}
    end

    test "rejects .exe extension" do
      profile = insert(:profile)

      assert {:ok, {:error, :invalid_file_type}} =
               Profiles.consume_avatar_upload(profile, upload_stub(), entry("virus.exe"), %{})
    end

    test "rejects .svg extension" do
      profile = insert(:profile)

      assert {:ok, {:error, :invalid_file_type}} =
               Profiles.consume_avatar_upload(profile, upload_stub(), entry("image.svg"), %{})
    end

    test "rejects .php extension" do
      profile = insert(:profile)

      assert {:ok, {:error, :invalid_file_type}} =
               Profiles.consume_avatar_upload(profile, upload_stub(), entry("script.php"), %{})
    end

    test "rejects file without extension" do
      profile = insert(:profile)

      assert {:ok, {:error, :invalid_file_type}} =
               Profiles.consume_avatar_upload(profile, upload_stub(), entry("noextension"), %{})
    end
  end

  describe "consume_avatar_upload/4 - file size validation" do
    # The size checked is the file's own, not the size the client reported.
    @tag :tmp_dir
    test "rejects a file over 10MB whatever size the client reported", %{tmp_dir: tmp_dir} do
      profile = insert(:profile)
      path = sized_file(tmp_dir, 10_000_001)

      assert {:ok, {:error, {:file_too_large, 10}}} =
               Profiles.consume_avatar_upload(
                 profile,
                 upload_stub(path),
                 entry("photo.jpg", 1),
                 %{}
               )
    end

    @tag :tmp_dir
    test "accepts a file of exactly 10MB", %{tmp_dir: tmp_dir} do
      profile = insert(:profile)
      path = sized_file(tmp_dir, 10_000_000)

      # At the limit validation passes, so the call runs on to the content
      # check, which refuses the zero bytes. An off-by-one in the size check
      # would surface {:file_too_large, 10} instead.
      assert Profiles.consume_avatar_upload(profile, upload_stub(path), entry("photo.jpg"), %{}) ==
               {:ok, {:error, :invalid_image_format}}
    end

    test "refuses an upload whose file cannot be read" do
      profile = insert(:profile)

      assert Profiles.consume_avatar_upload(profile, upload_stub(), entry("photo.jpg"), %{}) ==
               {:ok, {:error, :unreadable_file}}
    end
  end

  describe "consume_avatar_upload/4 - stored name" do
    test "is generated from the image's format, never from the client's name" do
      profile = insert(:profile)
      path = Path.join(System.tmp_dir!(), "avatar_#{System.unique_integer([:positive])}")
      File.cp!(MediaFixtures.path("gps.png"), path)

      assert {:ok, %{avatar: avatar}} =
               Profiles.consume_avatar_upload(
                 profile,
                 upload_stub(path),
                 entry("../../etc/passwd.jpg"),
                 %{}
               )

      assert avatar =~ ~r/\A[0-9a-f-]{36}\.png\z/
      assert File.exists?(Path.join([Uploads.root(), "avatars", to_string(profile.id), avatar]))
    end
  end

  describe "consume_avatar_upload/4 - a store that fails" do
    # That a failed write leaves no partial file is pinned where the write
    # happens, in `ImageMetadataTest`.
    test "leaves the current avatar in place" do
      profile = insert(:profile, avatar: "current.png")
      dir = Path.join([Uploads.root(), "avatars", to_string(profile.id)])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "current.png"), "current")

      path = Path.join(System.tmp_dir!(), "avatar_#{System.unique_integer([:positive])}")
      File.cp!(MediaFixtures.path("gps.png"), path)

      # The re-encoded image cannot be written into a read-only directory.
      File.chmod!(dir, 0o500)
      on_exit(fn -> File.chmod(dir, 0o700) && File.rm_rf(dir) end)

      assert {:ok, {:error, :eacces}} =
               Profiles.consume_avatar_upload(profile, upload_stub(path), entry("photo.png"), %{})

      assert File.ls!(dir) == ["current.png"]
      assert Repo.reload!(profile).avatar == "current.png"
    end
  end

  defp sized_file(dir, bytes) do
    path = Path.join(dir, "upload")
    File.write!(path, :binary.copy(<<0>>, bytes))
    path
  end
end
