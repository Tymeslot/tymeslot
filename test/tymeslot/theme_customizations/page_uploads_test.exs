defmodule Tymeslot.ThemeCustomizations.PageUploadsTest do
  # Swaps the global upload directory, so it cannot run concurrently.
  use Tymeslot.DataCase, async: false

  @moduletag :themes

  import Tymeslot.Factory

  alias Tymeslot.Test.MediaFixtures
  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.ThemeCustomizations.Storage

  setup do
    upload_root =
      Path.join(System.tmp_dir!(), "tymeslot_uploads_#{System.unique_integer([:positive])}")

    original_root = Application.get_env(:tymeslot, :upload_directory)
    Application.put_env(:tymeslot, :upload_directory, upload_root)

    on_exit(fn ->
      Application.put_env(:tymeslot, :upload_directory, original_root)
      File.rm_rf(upload_root)
    end)

    profile = insert(:profile)
    page = insert(:booking_page, profile: profile)
    %{profile: profile, page: page}
  end

  defp store!(scope, filename) do
    temp = MediaFixtures.temp_copy!("gps.webp")

    {:ok, path} =
      ThemeCustomizations.store_background_image(scope, "1", %{path: temp, filename: filename})

    path
  end

  test "a page's upload never replaces or deletes the profile's file of the same name", ctx do
    profile_path = store!(ctx.profile.id, "bg.webp")
    page_path = store!({ctx.profile.id, ctx.page.id}, "bg.webp")

    refute profile_path == page_path
    assert Path.basename(page_path) =~ "page-#{ctx.page.id}-"

    insert(:theme_customization,
      profile: ctx.profile,
      theme_id: "1",
      background_type: "image",
      background_value: "custom",
      background_image_path: profile_path
    )

    insert(:theme_customization,
      profile: ctx.profile,
      booking_page: ctx.page,
      theme_id: "1",
      background_type: "image",
      background_value: "custom",
      background_image_path: page_path
    )

    assert :ok = ThemeCustomizations.delete_page_customizations(ctx.page.id)

    assert File.exists?(Storage.build_theme_file_path(profile_path))
    refute File.exists?(Storage.build_theme_file_path(page_path))
  end
end
