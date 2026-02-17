defmodule Tymeslot.Security.SettingsInputProcessorTest do
  use Tymeslot.DataCase, async: true
  alias Tymeslot.Security.SettingsInputProcessor

  describe "validate_full_name_update/2" do
    test "accepts valid full name" do
      assert {:ok, "John Smith"} = SettingsInputProcessor.validate_full_name_update("John Smith")
    end

    test "rejects invalid full name" do
      # Note: FullNameValidator doesn't have min length, but rejects invalid chars
      assert {:error, "Full name contains invalid characters"} =
               SettingsInputProcessor.validate_full_name_update("John<script>")
    end
  end

  describe "validate_username_update/2" do
    test "accepts valid username" do
      # Note: UsernameValidator likely allows lowercase/numbers/underscores
      assert {:ok, "john_doe"} = SettingsInputProcessor.validate_username_update("john_doe")
    end

    test "rejects invalid username" do
      # Assuming UsernameValidator rejects very short usernames
      assert {:error, _reason} = SettingsInputProcessor.validate_username_update("a")
    end
  end

  describe "validate_timezone_update/2" do
    test "accepts valid timezone" do
      assert {:ok, "Europe/London"} =
               SettingsInputProcessor.validate_timezone_update("Europe/London")

      assert {:ok, "UTC"} = SettingsInputProcessor.validate_timezone_update("UTC")
    end

    test "rejects invalid timezone format" do
      assert {:error, "Invalid timezone format"} =
               SettingsInputProcessor.validate_timezone_update("InvalidTimezone")
    end
  end

  describe "validate_avatar_upload/2" do
    test "accepts valid image file" do
      params = %{"client_name" => "avatar.png", "size" => 1024}
      assert {:ok, ^params} = SettingsInputProcessor.validate_avatar_upload(params)
    end

    test "rejects invalid file type" do
      params = %{"client_name" => "malicious.exe", "size" => 1024}

      assert {:error, "Invalid file type. Only JPG, PNG, GIF, and WebP files are allowed"} =
               SettingsInputProcessor.validate_avatar_upload(params)
    end

    test "rejects large file" do
      params = %{"client_name" => "huge.jpg", "size" => 11_000_000}

      assert {:error, "File too large. Maximum size is 10MB"} =
               SettingsInputProcessor.validate_avatar_upload(params)
    end

    test "rejects dangerous file names" do
      params = %{"client_name" => "../../../etc/passwd.png", "size" => 1024}
      assert {:error, "Invalid file name"} = SettingsInputProcessor.validate_avatar_upload(params)
    end
  end
end
