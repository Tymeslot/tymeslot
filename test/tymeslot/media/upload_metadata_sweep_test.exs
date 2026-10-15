defmodule Tymeslot.Media.UploadMetadataSweepTest do
  use ExUnit.Case, async: true

  @moduletag :security
  @moduletag :integration
  @moduletag :tmp_dir

  alias Tymeslot.Media.UploadMetadataSweep
  alias Tymeslot.Test.MediaFixtures

  @layout %{
    "avatars/7/7_avatar_1.jpg" => "gps_portrait.jpg",
    "avatars/7/7_avatar_2.png" => "gps.png",
    "themes/7/1/images/garden.webp" => "gps.webp",
    "themes/7/1/videos/clip.mp4" => "gps.mp4",
    "themes/7/1/videos/clip-desktop.webm" => "gps.webm",
    "themes/7/1/videos/old.MOV" => "gps.mp4"
  }

  setup %{tmp_dir: upload_dir} do
    for {relative, fixture} <- @layout do
      path = Path.join(upload_dir, relative)
      File.mkdir_p!(Path.dirname(path))
      File.cp!(MediaFixtures.path(fixture), path)
    end

    :ok
  end

  test "strips every image and video already uploaded", %{tmp_dir: upload_dir} do
    assert %{stripped: 6, unchanged: 0, failed: []} = UploadMetadataSweep.run(upload_dir)

    images = ~w(avatars/7/7_avatar_1.jpg avatars/7/7_avatar_2.png themes/7/1/images/garden.webp)

    for relative <- images do
      contents = File.read!(Path.join(upload_dir, relative))
      assert MediaFixtures.image_metadata_fields(contents) == [], relative
    end

    portrait = File.read!(Path.join(upload_dir, "avatars/7/7_avatar_1.jpg"))
    assert MediaFixtures.image_dimensions(portrait) == {16, 32}

    for relative <- ["themes/7/1/videos/clip.mp4", "themes/7/1/videos/old.MOV"] do
      refute File.read!(Path.join(upload_dir, relative)) =~ "location.ISO6709", relative
    end

    refute File.read!(Path.join(upload_dir, "themes/7/1/videos/clip-desktop.webm")) =~ "51.5007"
  end

  test "a second run leaves every file as the first left it", %{tmp_dir: upload_dir} do
    UploadMetadataSweep.run(upload_dir)
    after_first = contents(upload_dir)

    assert %{stripped: 0, unchanged: 6, failed: []} = UploadMetadataSweep.run(upload_dir)
    assert contents(upload_dir) == after_first
  end

  @tag :capture_log
  test "reports a file it cannot process and carries on", %{tmp_dir: upload_dir} do
    broken = Path.join(upload_dir, "avatars/8/8_avatar_1.jpg")
    File.mkdir_p!(Path.dirname(broken))
    File.write!(broken, "not an image")

    assert %{stripped: 6, failed: [{^broken, :invalid_image_format}]} =
             UploadMetadataSweep.run(upload_dir)
  end

  test "leaves files that are not images or videos, and symbolic links, alone", %{
    tmp_dir: upload_dir
  } do
    notes = Path.join(upload_dir, "notes.txt")
    File.write!(notes, "keep me")
    link = Path.join(upload_dir, "link.jpg")
    File.ln_s!(MediaFixtures.path("gps_portrait.jpg"), link)

    assert %{stripped: 6, unchanged: 0, failed: []} = UploadMetadataSweep.run(upload_dir)
    assert File.read!(notes) == "keep me"
    assert File.read!(link) == MediaFixtures.read!("gps_portrait.jpg")
  end

  defp contents(upload_dir) do
    Map.new(@layout, fn {relative, _fixture} ->
      {relative, File.read!(Path.join(upload_dir, relative))}
    end)
  end
end
