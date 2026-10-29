defmodule Tymeslot.ThemeCustomizations.PageUploadsTest do
  # Swaps the global upload directory, so it cannot run concurrently.
  use Tymeslot.DataCase, async: false

  @moduletag :themes

  import Tymeslot.Factory

  alias Tymeslot.Test.MediaFixtures
  alias Tymeslot.Test.UploadRoot
  alias Tymeslot.ThemeCustomizations

  setup do
    UploadRoot.isolate("tymeslot_page_uploads")

    profile = insert(:profile)
    page = insert(:booking_page, profile: profile)
    %{profile: profile, page: page}
  end

  defp attach!(scope, filename) do
    temp = MediaFixtures.temp_copy!("gps.webp")

    {:ok, customization} =
      ThemeCustomizations.attach_asset(scope, "1", :background_image_path, %{
        path: temp,
        filename: filename
      })

    customization.settings["background_image_path"]
  end

  test "a page's upload never replaces or deletes the profile's file of the same name", ctx do
    profile_path = attach!(ctx.profile.id, "bg.webp")
    page_path = attach!({ctx.profile.id, ctx.page.id}, "bg.webp")

    refute profile_path == page_path

    assert %{booking_page_id: page_id} =
             ThemeCustomizations.get_by_profile_and_theme({ctx.profile.id, ctx.page.id}, "1")

    assert page_id == ctx.page.id

    assert :ok = ThemeCustomizations.delete_page_customizations(ctx.page.id)

    assert File.exists?(UploadRoot.path(profile_path))
    refute File.exists?(UploadRoot.path(page_path))
  end
end
