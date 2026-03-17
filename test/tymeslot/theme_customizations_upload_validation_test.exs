defmodule Tymeslot.ThemeCustomizationsUploadValidationTest do
  use Tymeslot.DataCase, async: true
  @moduletag :utils

  alias Tymeslot.ThemeCustomizations.Validation

  describe "Validation file upload tests" do
    test "validate_file_upload/1 requires path and filename" do
      assert {:error, _reason} = Validation.validate_file_upload(%{})
      assert {:error, _reason} = Validation.validate_file_upload(%{path: "test"})
      assert {:error, _reason} = Validation.validate_file_upload(%{filename: "test"})
    end

    test "validate_file_upload/1 validates file exists" do
      assert {:error, _reason} =
               Validation.validate_file_upload(%{
                 path: "/nonexistent/file.jpg",
                 filename: "test.jpg"
               })
    end

    test "validate_file_upload/1 validates filename not empty" do
      temp_file = Path.join(System.tmp_dir!(), "test_upload_#{:rand.uniform(100_000)}.jpg")
      File.write!(temp_file, "data")

      try do
        assert {:error, msg} =
                 Validation.validate_file_upload(%{path: temp_file, filename: "   "})

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
      assert {:error, _reason} = Validation.validate_file_size("/nonexistent/file.jpg", :image)
    end

    test "validate_file_size/2 accepts image at exactly the 20MB limit" do
      temp_file = Path.join(System.tmp_dir!(), "test_exact_#{:rand.uniform(100_000)}.jpg")
      # Write exactly 20_000_000 bytes
      File.write!(temp_file, :binary.copy(<<0>>, 20_000_000))

      try do
        assert Validation.validate_file_size(temp_file, :image) == :ok
      after
        File.rm(temp_file)
      end
    end

    test "validate_file_size/2 rejects image one byte over the 20MB limit" do
      temp_file = Path.join(System.tmp_dir!(), "test_over_#{:rand.uniform(100_000)}.jpg")
      File.write!(temp_file, :binary.copy(<<0>>, 20_000_001))

      try do
        assert {:error, message} = Validation.validate_file_size(temp_file, :image)
        assert message =~ "too large"
        assert message =~ "20.0MB"
      after
        File.rm(temp_file)
      end
    end

    test "validate_file_size/2 accepts video at exactly the 100MB limit" do
      temp_file = Path.join(System.tmp_dir!(), "test_video_exact_#{:rand.uniform(100_000)}.mp4")
      File.write!(temp_file, :binary.copy(<<0>>, 100 * 1024 * 1024))

      try do
        assert Validation.validate_file_size(temp_file, :video) == :ok
      after
        File.rm(temp_file)
      end
    end
  end
end
