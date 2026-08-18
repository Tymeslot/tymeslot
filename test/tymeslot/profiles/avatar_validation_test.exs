defmodule Tymeslot.Profiles.AvatarValidationTest do
  use Tymeslot.DataCase, async: true

  @moduletag :profiles

  alias Tymeslot.Profiles

  # consume_avatar_upload/4 wraps validation errors as {:ok, {:error, reason}}
  # so validation failures are fully testable without touching the filesystem.

  defp upload_stub(path \\ "/tmp/test_upload"), do: %{path: path}
  defp entry(name, size \\ 1_000), do: %{client_name: name, client_size: size}

  describe "consume_avatar_upload/4 - file type validation" do
    test "accepts .jpg extension" do
      profile = insert(:profile)
      result = Profiles.consume_avatar_upload(profile, upload_stub(), entry("photo.jpg"), %{})

      # Validation passes, so the call runs on to the file copy, which fails
      # with :enoent because the stub path names no real file. A rejected
      # extension would surface the validation message string instead.
      assert result == {:ok, {:error, :enoent}}
    end

    test "rejects .exe extension" do
      profile = insert(:profile)

      assert {:ok, {:error, "Invalid file type. Only JPG, PNG, GIF, and WebP files are allowed"}} =
               Profiles.consume_avatar_upload(profile, upload_stub(), entry("virus.exe"), %{})
    end

    test "rejects .svg extension" do
      profile = insert(:profile)

      assert {:ok, {:error, "Invalid file type. Only JPG, PNG, GIF, and WebP files are allowed"}} =
               Profiles.consume_avatar_upload(profile, upload_stub(), entry("image.svg"), %{})
    end

    test "rejects .php extension" do
      profile = insert(:profile)

      assert {:ok, {:error, "Invalid file type. Only JPG, PNG, GIF, and WebP files are allowed"}} =
               Profiles.consume_avatar_upload(profile, upload_stub(), entry("script.php"), %{})
    end

    test "rejects file without extension" do
      profile = insert(:profile)

      assert {:ok, {:error, "Invalid file type. Only JPG, PNG, GIF, and WebP files are allowed"}} =
               Profiles.consume_avatar_upload(profile, upload_stub(), entry("noextension"), %{})
    end
  end

  describe "consume_avatar_upload/4 - file size validation" do
    test "rejects files larger than 10MB" do
      profile = insert(:profile)
      over_limit = 10_000_001

      assert {:ok, {:error, "File too large. Maximum size is 10MB"}} =
               Profiles.consume_avatar_upload(
                 profile,
                 upload_stub(),
                 entry("photo.jpg", over_limit),
                 %{}
               )
    end

    test "accepts files at exactly 10MB" do
      profile = insert(:profile)

      result =
        Profiles.consume_avatar_upload(
          profile,
          upload_stub(),
          entry("photo.jpg", 10_000_000),
          %{}
        )

      # Exactly at the limit validation passes, so the call runs on to the file
      # copy and fails with :enoent on the stub path. An off-by-one in the size
      # check would surface the "File too large" message instead.
      assert result == {:ok, {:error, :enoent}}
    end
  end

  describe "consume_avatar_upload/4 - file name validation" do
    test "rejects path traversal with ../" do
      profile = insert(:profile)

      assert {:ok, {:error, "Invalid file name"}} =
               Profiles.consume_avatar_upload(
                 profile,
                 upload_stub(),
                 entry("../etc/passwd.jpg"),
                 %{}
               )
    end

    test "rejects path traversal with ..\\" do
      profile = insert(:profile)

      assert {:ok, {:error, "Invalid file name"}} =
               Profiles.consume_avatar_upload(
                 profile,
                 upload_stub(),
                 entry("..\\windows\\system32.jpg"),
                 %{}
               )
    end

    test "rejects null byte in filename" do
      profile = insert(:profile)

      assert {:ok, {:error, "Invalid file name"}} =
               Profiles.consume_avatar_upload(
                 profile,
                 upload_stub(),
                 entry("photo\0.jpg"),
                 %{}
               )
    end

    test "rejects filename with special characters" do
      profile = insert(:profile)

      assert {:ok, {:error, "Invalid file name"}} =
               Profiles.consume_avatar_upload(
                 profile,
                 upload_stub(),
                 entry("photo<script>.jpg"),
                 %{}
               )
    end

    test "rejects filename exceeding 255 characters" do
      profile = insert(:profile)
      long_name = String.duplicate("a", 252) <> ".jpg"

      assert {:ok, {:error, "File name too long"}} =
               Profiles.consume_avatar_upload(profile, upload_stub(), entry(long_name), %{})
    end
  end
end
