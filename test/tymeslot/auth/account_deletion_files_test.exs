defmodule Tymeslot.Auth.AccountDeletionFilesTest do
  @moduledoc """
  `Auth.delete_account/1` removes rows by foreign-key cascade, and a cascade
  never touches the filesystem. An avatar is usually a photo of the person, so
  the files the deleted rows pointed at are personal data that must go with
  them. `account_deletion_cascade_test.exs` pins the rows; this pins the files.

  Async-safe: the test upload directory is already a per-run temp directory,
  and every path here is keyed by a profile id no other test shares.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :auth
  @moduletag :profiles

  import Tymeslot.Factory

  alias Tymeslot.Auth

  defp upload_path(parts) do
    Path.join([Application.fetch_env!(:tymeslot, :upload_directory) | parts])
  end

  defp write_file!(parts) do
    path = upload_path(parts)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "bytes")
    path
  end

  defp profile_with_uploads do
    profile = insert(:profile, avatar: "avatar_current.png")
    id = Integer.to_string(profile.id)

    image = "themes/#{id}/1/images/background.jpg"
    video = "themes/#{id}/2/videos/background.mp4"

    insert(:theme_customization,
      profile: profile,
      theme_id: "1",
      background_type: "image",
      background_image_path: image
    )

    insert(:theme_customization,
      profile: profile,
      theme_id: "2",
      background_type: "video",
      background_video_path: video
    )

    files = [
      write_file!(["avatars", id, "avatar_current.png"]),
      # A replaced avatar no row references any more.
      write_file!(["avatars", id, "avatar_old.png"]),
      write_file!([image]),
      write_file!([video]),
      write_file!(["themes", id, "2", "videos", "background_720p.mp4"])
    ]

    {profile, files}
  end

  test "removes the deleted profile's avatars and theme backgrounds from disk" do
    {profile, files} = profile_with_uploads()

    assert {:ok, _deleted} = Auth.delete_account(profile.user)

    assert Enum.filter(files, &File.exists?/1) == []
    refute File.exists?(upload_path(["avatars", Integer.to_string(profile.id)]))
    refute File.exists?(upload_path(["themes", Integer.to_string(profile.id)]))
  end

  test "leaves every other profile's uploads in place" do
    {deleted_profile, _files} = profile_with_uploads()
    {_kept_profile, kept_files} = profile_with_uploads()

    assert {:ok, _deleted} = Auth.delete_account(deleted_profile.user)

    assert Enum.reject(kept_files, &File.exists?/1) == []
  end

  test "deletes an account that never had a profile" do
    user = insert(:user)

    assert {:ok, _deleted} = Auth.delete_account(user)
  end
end
