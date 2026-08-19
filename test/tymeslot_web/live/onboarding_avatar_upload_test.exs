defmodule TymeslotWeb.OnboardingAvatarUploadTest do
  @moduledoc """
  Verifies a successful avatar upload on the onboarding profile step clears
  the file picker by pushing the "upload-complete" event the `AutoUpload`
  hook listens for, mirroring the dashboard avatar upload fix.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :onboarding
  @moduletag :live

  import Mox
  import TymeslotWeb.OnboardingTestHelpers

  # Minimal valid PNG (magic bytes + IHDR) — accepted by allow_upload's accept
  # list without triggering the file-size limit.
  @valid_png <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, "IHDR", 0, 0, 0, 1, 0,
               0, 0, 1, 8, 2, 0, 0, 0, 0x90, 0x77, 0x53, 0xDE>>

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
  end
end
