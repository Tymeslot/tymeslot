defmodule TymeslotWeb.OnboardingAvatarRateLimitTest do
  @moduledoc """
  Verifies that a rate-limited avatar upload in the onboarding flow frees the
  single upload slot so the user can retry without a page refresh.

  Must run with `async: false` because rate-limit state lives in a shared ETS
  table that is cleared in setup.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :live
  @moduletag :security

  import Mox
  import TymeslotWeb.OnboardingTestHelpers

  alias Tymeslot.Security.RateLimiter

  # Minimal valid PNG (magic bytes + IHDR) — accepted by allow_upload's accept
  # list without triggering the file-size limit.
  @valid_png <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, "IHDR", 0, 0, 0, 1, 0,
               0, 0, 1, 8, 2, 0, 0, 0, 0x90, 0x77, 0x53, 0xDE>>

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    RateLimiter.clear_all()
    {:ok, conn: setup_onboarding_session(tags.conn)}
  end

  describe "avatar upload rate limiting" do
    test "rate-limited upload clears the entry and frees the slot for retry", %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding(conn)

      # Navigate to the profile step where the avatar upload form is present.
      view |> element("button[phx-click='next_step']") |> render_click()

      # Exhaust the avatar upload bucket (limit: 20 per hour).
      for _i <- 1..20 do
        RateLimiter.check_avatar_upload_rate_limit(user.id)
      end

      avatar = %{
        last_modified: System.system_time(:millisecond),
        name: "avatar.png",
        content: @valid_png,
        type: "image/png"
      }

      # First upload attempt — the rate limiter will deny it.
      view
      |> file_input("#onboarding-avatar-form", :avatar, [avatar])
      |> render_upload("avatar.png")

      html = render(view)

      # The flash error must be present.
      assert html =~ "reached the limit of 20 avatar upload"

      # The entry must have been cancelled — no "Processing…" spinner stuck on screen.
      refute html =~ "Processing…"

      # Second upload attempt — proves the slot was freed (no :too_many_files).
      view
      |> file_input("#onboarding-avatar-form", :avatar, [avatar])
      |> render_upload("avatar.png")

      html = render(view)
      refute html =~ "Too many files"
      refute html =~ "Processing…"
    end
  end
end
