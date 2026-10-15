defmodule TymeslotWeb.OnboardingAvatarUploadTest do
  @moduledoc """
  Verifies a successful avatar upload on the onboarding profile step clears
  the file picker by pushing the "upload-complete" event the `AutoUpload`
  hook listens for, mirroring the dashboard avatar upload fix.
  """

  use TymeslotWeb.LiveCase, async: false

  alias Tymeslot.Profiles
  alias Tymeslot.Test.MediaFixtures

  @moduletag :onboarding
  @moduletag :live

  import Mox
  import TymeslotWeb.OnboardingTestHelpers

  # Complete and decodable: a stored image is re-encoded, so magic bytes
  # alone are refused.
  @valid_png MediaFixtures.png()

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    {:ok, conn: setup_onboarding_session(tags.conn)}
  end

  describe "avatar upload" do
    test "a successful upload pushes upload-complete so the AutoUpload hook clears the picker",
         %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)

      # Navigate to the profile step where the avatar upload form is present.
      view |> element("button[phx-click='next_step']") |> render_click()

      html = render(view)

      # The file input must be inside the hook's element for clearFileInputs
      # (assets/js/hooks/auto_upload.js) to find it via this.el.querySelectorAll.
      assert html =~ ~r/id="onboarding-avatar-upload-group"[^>]*phx-hook="AutoUpload"/

      avatar = %{
        last_modified: System.system_time(:millisecond),
        name: "avatar.png",
        content: @valid_png,
        type: "image/png"
      }

      view
      |> file_input("#onboarding-avatar-form", :avatar, [avatar])
      |> render_upload("avatar.png")

      assert_push_event(view, "upload-complete", %{})
    end

    test "refuses an image over 40 megapixels and says how large it may be", %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding(conn)
      view |> element("button[phx-click='next_step']") |> render_click()

      avatar = %{
        last_modified: System.system_time(:millisecond),
        name: "huge.png",
        content: MediaFixtures.png_declaring(20_000, 20_000),
        type: "image/png"
      }

      view
      |> file_input("#onboarding-avatar-form", :avatar, [avatar])
      |> render_upload("huge.png")

      assert render(view) =~
               "This image is too large (400.0 megapixels). " <>
                 "Please upload an image of at most 40 megapixels."

      assert Profiles.get_profile(user.id).avatar == nil
    end
  end
end
