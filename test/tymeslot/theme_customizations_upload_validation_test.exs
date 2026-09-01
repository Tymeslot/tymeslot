defmodule Tymeslot.ThemeCustomizationsUploadValidationTest do
  use Tymeslot.DataCase, async: true
  @moduletag :utils

  alias Tymeslot.ThemeCustomizations.Validation
  alias TymeslotWeb.Helpers.UploadConstraints

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

    # The caps below are the ones `allow_upload` enforces at preflight. They were
    # restated here as literals and drifted: the video branch allowed 100 MiB
    # while the uploader refused anything over 100 MB, so a ~102 MB file passed
    # this validator and was then rejected on its way in. Drive the boundary from
    # `UploadConstraints` so the two cannot part again.

    test "validate_file_size/2 caps an image at UploadConstraints.max_file_size(:image)" do
      max_size = UploadConstraints.max_file_size(:image)
      temp_file = Path.join(System.tmp_dir!(), "test_exact_#{:rand.uniform(100_000)}.jpg")

      try do
        File.write!(temp_file, :binary.copy(<<0>>, max_size + 1))
        assert {:error, message} = Validation.validate_file_size(temp_file, :image)
        assert message =~ "too large"
        assert message =~ "20.0MB"

        File.write!(temp_file, :binary.copy(<<0>>, max_size))
        assert Validation.validate_file_size(temp_file, :image) == :ok
      after
        File.rm(temp_file)
      end
    end

    test "validate_file_size/2 caps a video at UploadConstraints.max_file_size(:video)" do
      max_size = UploadConstraints.max_file_size(:video)
      temp_file = Path.join(System.tmp_dir!(), "test_video_exact_#{:rand.uniform(100_000)}.mp4")

      try do
        File.write!(temp_file, :binary.copy(<<0>>, max_size + 1))
        assert {:error, message} = Validation.validate_file_size(temp_file, :video)
        assert message =~ "too large"
        assert message =~ "100.0MB"

        File.write!(temp_file, :binary.copy(<<0>>, max_size))
        assert Validation.validate_file_size(temp_file, :video) == :ok
      after
        File.rm(temp_file)
      end
    end
  end
end
