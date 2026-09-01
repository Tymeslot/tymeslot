defmodule TymeslotWeb.OnboardingAvatarConcurrentUploadTest do
  @moduledoc """
  Guards the onboarding avatar upload against the entry that never finishes.

  `consume_uploaded_entries/3` raises `ArgumentError` if *any* entry on the
  upload is still in progress, while the auto-upload progress callback runs once
  per entry and sees only its own. A second selected file — excess against
  `max_entries: 1`, and so never issued an upload token — therefore used to take
  the whole onboarding LiveView down the moment the first file finished,
  leaving a new user unable to complete signup.

  The excess entry is *valid*: LiveView records `:too_many_files` against the
  upload config rather than the entry. Cancelling only invalid entries turns the
  crash into a silent drop, so these tests assert the photo reached the profile
  rather than merely that the page survived.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :live
  @moduletag :onboarding

  import Mox
  import TymeslotWeb.OnboardingTestHelpers

  alias Tymeslot.Profiles
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

  defp stored_avatar(user) do
    {:ok, profile} = Profiles.get_profile_by_user_id(user.id)
    profile.avatar
  end

  describe "avatar upload with an entry that cannot finish" do
    test "stores the finished photo when a second file exceeds the upload slot",
         %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding(conn)
      view = goto_profile_step(view)

      # Two files in one selection against `max_entries: 1`. Only the first is
      # preflighted; the second can never finish, but it is `valid?: true`.
      input = file_input(view, "#onboarding-avatar-form", :avatar, [png("a.png"), png("b.png")])

      render_upload(input, "a.png")

      # The LiveView must still be alive and serving: before the crash fix,
      # consuming the finished entry raised ArgumentError and killed it.
      assert render(view) =~ "onboarding-avatar-form"

      # …and the photo the user actually uploaded must have landed. Without the
      # excess entry being cancelled, `settle_upload/2` reports `:in_progress`
      # forever and this stays nil.
      assert_push_event(view, "upload-complete", %{})
      assert stored_avatar(user) =~ ".png"
    end

    test "a later clean upload still lands after the excess entry", %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding(conn)
      view = goto_profile_step(view)

      input = file_input(view, "#onboarding-avatar-form", :avatar, [png("a.png"), png("b.png")])
      render_upload(input, "a.png")
      first = stored_avatar(user)
      assert first =~ ".png"

      # A single, clean upload afterwards must replace it, proving the cancelled
      # entry freed the slot rather than wedging the upload for good.
      retry = file_input(view, "#onboarding-avatar-form", :avatar, [png("c.png")])
      render_upload(retry, "c.png")

      second = stored_avatar(user)
      assert second =~ ".png"
      assert second != first
      refute render(view) =~ "Processing…"
    end
  end
end
