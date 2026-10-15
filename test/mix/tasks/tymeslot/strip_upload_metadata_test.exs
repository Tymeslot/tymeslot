defmodule Mix.Tasks.Tymeslot.StripUploadMetadataTest do
  # Points the configured upload directory, which is global, at a temp dir.
  use ExUnit.Case, async: false

  @moduletag :security
  @moduletag :tmp_dir

  import ExUnit.CaptureIO

  alias Mix.Tasks.Tymeslot.StripUploadMetadata
  alias Tymeslot.Test.MediaFixtures

  setup %{tmp_dir: upload_dir} do
    original = Application.get_env(:tymeslot, :upload_directory)
    Application.put_env(:tymeslot, :upload_directory, upload_dir)
    on_exit(fn -> Application.put_env(:tymeslot, :upload_directory, original) end)

    avatar = Path.join(upload_dir, "avatars/1/1_avatar.jpg")
    File.mkdir_p!(Path.dirname(avatar))
    File.cp!(MediaFixtures.path("gps_portrait.jpg"), avatar)

    %{avatar: avatar}
  end

  @tag :capture_log
  test "strips the configured upload directory and says how many files it changed", %{
    avatar: avatar
  } do
    output = capture_io(fn -> StripUploadMetadata.run([]) end)

    assert output =~ "Stripped 1 file(s); 0 had no metadata to remove."
    assert MediaFixtures.image_metadata_fields(File.read!(avatar)) == []
  end

  @tag :capture_log
  test "fails, naming each file it could not process", %{tmp_dir: upload_dir} do
    broken = Path.join(upload_dir, "avatars/1/broken.png")
    File.write!(broken, "not an image")

    error_output =
      capture_io(:stderr, fn ->
        assert_raise Mix.Error, ~r/1 file\(s\) could not be processed/, fn ->
          capture_io(fn -> StripUploadMetadata.run([]) end)
        end
      end)

    assert error_output =~ "Could not process #{broken}"
  end
end
