defmodule TymeslotWeb.OnboardingAvatarConcurrentUploadTest do
  @moduledoc """
  Guards the onboarding avatar upload against the entry that never finishes.

  `consume_uploaded_entries/3` raises `ArgumentError` if *any* entry on the
  upload is still in progress, while the auto-upload progress callback runs once
  per entry and sees only its own. A second selected file — rejected as excess
  by `max_entries: 1`, and so never uploaded — therefore used to take the whole
  onboarding LiveView down the moment the first file finished, leaving a new
  user unable to complete signup.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :live
  @moduletag :onboarding

  import Mox
  import TymeslotWeb.OnboardingTestHelpers

  alias Tymeslot.Security.RateLimiter

  # Minimal valid PNG (magic bytes + IHDR): passes the accept list and the
  # size limit without needing a fixture on disk.
  @valid_png <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, "IHDR", 0, 0, 0, 1, 0,
               0, 0, 1, 8, 2, 0, 0, 0, 0x90, 0x77, 0x53, 0xDE>>

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    {:ok, conn: setup_onboarding_session(tags.conn)}
  end

  defp png(name) do
    %{
      last_modified: System.system_time(:millisecond),
      name: name,
      content: @valid_png,
      type: "image/png"
    }
  end

  defp goto_profile_step(view) do
    view |> element("button[phx-click='next_step']") |> render_click()
    view
  end

  describe "avatar upload with an entry that cannot finish" do
    test "survives a second file the upload slot cannot accept", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      view = goto_profile_step(view)

      # Two files against `max_entries: 1`. The excess entry is invalid, is
      # never uploaded, and so stays not-done for the life of the LiveView.
      input = file_input(view, "#onboarding-avatar-form", :avatar, [png("a.png"), png("b.png")])

      render_upload(input, "a.png")

      # The LiveView must still be alive and serving: before the fix, consuming
      # the finished entry raised ArgumentError here and killed the process.
      assert render(view) =~ "onboarding-avatar-form"
    end

    test "still consumes the upload once the blocking entry is gone", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      view = goto_profile_step(view)

      input = file_input(view, "#onboarding-avatar-form", :avatar, [png("a.png"), png("b.png")])
      render_upload(input, "a.png")

      # A single, clean upload afterwards must still land, proving the cancelled
      # entry freed the slot rather than wedging the upload for good.
      retry = file_input(view, "#onboarding-avatar-form", :avatar, [png("c.png")])
      render_upload(retry, "c.png")

      refute render(view) =~ "Processing…"
    end
  end
end
