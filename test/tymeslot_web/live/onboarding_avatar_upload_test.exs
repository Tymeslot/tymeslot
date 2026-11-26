defmodule TymeslotWeb.OnboardingAvatarUploadTest do
  @moduledoc """
  Avatar uploads on the onboarding profile step: a picked image is stored on
  the profile as soon as it arrives, and one over the pixel limit is refused.
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
    test "a picked image is stored on the profile", %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding(conn)

      avatar = %{
        last_modified: System.system_time(:millisecond),
        name: "avatar.png",
        content: @valid_png,
        type: "image/png"
      }

      view
      |> file_input("#onboarding-avatar-form", :avatar, [avatar])
      |> render_upload("avatar.png")

      assert Profiles.get_profile(user.id).avatar =~ ".png"
    end

    test "refuses an image over 40 megapixels and says how large it may be", %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding(conn)

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
