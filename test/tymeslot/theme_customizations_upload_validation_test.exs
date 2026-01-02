defmodule Tymeslot.ThemeCustomizationsUploadValidationTest do
  use Tymeslot.DataCase, async: true

  alias Tymeslot.ThemeCustomizations.Validation

  describe "Validation file upload tests" do
    test "validate_file_upload/1 requires path and filename" do
      assert {:error, _} = Validation.validate_file_upload(%{})
      assert {:error, _} = Validation.validate_file_upload(%{path: "test"})
      assert {:error, _} = Validation.validate_file_upload(%{filename: "test"})
    end

    test "validate_file_upload/1 validates file exists" do
      assert {:error, _} =
               Validation.validate_file_upload(%{path: "/nonexistent/file.jpg", filename: "test.jpg"})
    end

    test "validate_file_upload/1 validates filename not empty" do
      temp_file = Path.join(System.tmp_dir!(), "test_upload_#{:rand.uniform(100_000)}.jpg")
      File.write!(temp_file, "data")

      try do
        assert {:error, msg} = Validation.validate_file_upload(%{path: temp_file, filename: "   "})
        assert msg =~ "empty"
      after
        File.rm(temp_file)
      end
    end

    test "validate_file_upload/1 accepts valid file" do
      temp_file = Path.join(System.tmp_dir!(), "test_upload_valid_#{:rand.uniform(100_000)}.jpg")
      File.write!(temp_file, "data")

      try do
        assert Validation.validate_file_upload(%{path: temp_file, filename: "valid.jpg"}) == :ok
      after
        File.rm(temp_file)
      end
    end

    test "validate_file_size/2 validates image size limit" do
      temp_file = Path.join(System.tmp_dir!(), "test_size_#{:rand.uniform(100_000)}.jpg")
      File.write!(temp_file, "small data")

      try do
        assert Validation.validate_file_size(temp_file, :image) == :ok
      after
        File.rm(temp_file)
      end
    end

    test "validate_file_size/2 validates video size limit" do
      temp_file = Path.join(System.tmp_dir!(), "test_video_size_#{:rand.uniform(100_000)}.mp4")
      File.write!(temp_file, "small video data")

      try do
        assert Validation.validate_file_size(temp_file, :video) == :ok
      after
        File.rm(temp_file)
      end
    end

    test "validate_file_size/2 returns error for non-existent file" do
      assert {:error, _} = Validation.validate_file_size("/nonexistent/file.jpg", :image)
    end
  end
end
