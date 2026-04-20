defmodule TymeslotWeb.Helpers.FileOperationsFilenameSecurityTest do
  @moduledoc """
  Regression for Task 96 — filename security validation used by the
  theme upload path.

  The avatar context performs its own null-byte check before reaching
  `FileOperations`, but theme uploads rely on
  `FileOperations.validate_upload_file/3` alone. Before Task 96, a
  filename containing a null byte or `../` sequence could pass straight
  through to `sanitize_filename/1`, which would paper over the attack
  silently instead of refusing the upload.
  """

  use ExUnit.Case, async: true

  @moduletag :utils

  alias TymeslotWeb.Helpers.FileOperations

  defp entry(filename, size \\ 1_000) do
    %{client_name: filename, client_size: size}
  end

  describe "validate_upload_file/3 — filename security" do
    test "rejects null byte anywhere in filename" do
      assert {:error, :null_byte_in_filename} =
               FileOperations.validate_upload_file(entry("evil\0.jpg"), :image)
    end

    test "rejects null byte before the extension" do
      assert {:error, :null_byte_in_filename} =
               FileOperations.validate_upload_file(entry("evil\0file.jpg"), :image)
    end

    test "rejects ../ path traversal in filename" do
      assert {:error, :path_traversal_in_filename} =
               FileOperations.validate_upload_file(entry("../etc/passwd.jpg"), :image)
    end

    test "rejects backslash path traversal (Windows-style)" do
      assert {:error, :path_traversal_in_filename} =
               FileOperations.validate_upload_file(entry("..\\windows\\system.jpg"), :image)
    end

    test "rejects home-directory reference" do
      assert {:error, :path_traversal_in_filename} =
               FileOperations.validate_upload_file(entry("~/.ssh/id_rsa.jpg"), :image)
    end

    test "rejects dotfile filenames" do
      assert {:error, :hidden_file_not_allowed} =
               FileOperations.validate_upload_file(entry(".htaccess.jpg"), :image)
    end

    test "accepts a plain, well-formed filename" do
      assert {:ok, sanitised} =
               FileOperations.validate_upload_file(entry("holiday-photo.jpg"), :image)

      assert sanitised.client_name == "holiday-photo.jpg"
    end
  end
end
