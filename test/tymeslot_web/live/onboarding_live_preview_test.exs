defmodule TymeslotWeb.OnboardingLivePreviewTest do
  @moduledoc """
  Covers the onboarding live-preview panel and the personalisation controls:
  the profile step (avatar, name, booking link) and the conditional
  `choose_theme` step (booking theme, colour scheme, real-page preview).

  These assert the user-visible journey: the right-hand mock reflects the
  organiser's in-progress data, the theme step appears only once a calendar is
  connected, and theme/colour selections persist and drive a real full-page
  preview of the booking page.
  """

  use TymeslotWeb.LiveCase, async: false
  @moduletag :onboarding

  import Phoenix.LiveViewTest
  import Tymeslot.Factory
  import TymeslotWeb.OnboardingTestHelpers

  alias Tymeslot.Bookings.Policy
  alias Tymeslot.Onboarding
  alias Tymeslot.Profiles
  alias Tymeslot.ThemeCustomizations
  alias TymeslotWeb.Themes.Core.ThemeInfo

  # 1x1 transparent PNG — a real image so the avatar magic-byte validation passes.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
       )

  setup tags do
    {:ok, conn: setup_onboarding_session(tags.conn)}
  end

  defp goto_profile(view) do
    view |> element("button[phx-click='next_step']") |> render_click()
    view
  end

  defp host do
    String.replace(Policy.app_url(), ~r{^https?://}, "")
  end

  describe "live preview reflects in-progress profile data" do
    test "welcome step shows the booking-page preview caption", %{conn: conn} do
      {:ok, _view, html, _user} = setup_onboarding(conn)
      assert html =~ "This is your live booking page"
    end

    test "profile step preview reflects the typed name and booking link", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      view = goto_profile(view)

      html = fill_profile(view, "Ada Lovelace", "ada")

      # Preview-specific markup: the profile caption and the joined link chip.
      assert html =~ "Your page, your brand"
      assert html =~ "Ada Lovelace"
      assert html =~ "#{host()}/ada"
    end
  end

  describe "live username validation" do
    test "flags a reserved username immediately while typing", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      view = goto_profile(view)

      html = fill_profile(view, "Ada Lovelace", "admin")

      assert html =~ "reserved"
    end

    test "flags an already-taken username immediately while typing", %{conn: conn} do
      insert(:profile, %{username: "takenslot"})

      {:ok, view, _html, _user} = setup_onboarding(conn)
      view = goto_profile(view)

      html = fill_profile(view, "Ada Lovelace", "takenslot")

      assert html =~ "already taken"
    end

    test "accepts an available username with no error", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      view = goto_profile(view)

      html = fill_profile(view, "Ada Lovelace", "ada-unique-handle")

      refute html =~ "reserved"
      refute html =~ "already taken"
    end
  end

  describe "choose_theme step gating" do
    test "is skipped when no calendar is connected", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      view = navigate_to_scheduling_steps(view)
      html = render(view)

      # Skipping the calendar lands straight on the buffer step — no theme step.
      refute html =~ "Your booking theme"
      assert html =~ "Buffer between meetings"
    end

    test "appears after the calendar step once a calendar is connected", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding_with_calendar(conn)
      html = view |> goto_choose_theme() |> render()

      assert html =~ "Your booking theme"
      assert html =~ "Preview booking page"
    end
  end

  describe "preview reshapes to the chosen theme" do
    test "starts as Quill (calendar grid) and switches to Rhythm on selection", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding_with_calendar(conn)
      view = goto_choose_theme(view)

      # Quill's signature month-calendar grid is present by default.
      assert render(view) =~ "grid-cols-7"

      html =
        view
        |> element("button[phx-value-theme='2']")
        |> render_click()

      # Rhythm has no month grid — its body is the compact week strip + list.
      refute html =~ "grid-cols-7"
    end
  end

  describe "real booking-page preview" do
    test "opens a full-page standalone preview of the user's own page", %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding_with_calendar(conn)
      view = goto_choose_theme(view)

      html =
        view
        |> element("button[phx-click='preview_booking_page']")
        |> render_click()

      {:ok, profile} = Profiles.get_or_create_profile(user.id)

      # The modal loads the real page standalone (no embed=1) so the video
      # background renders and the page fills the frame — preview=true alone
      # pins CSP frame-ancestors 'self' for same-origin framing.
      assert html =~ "/#{profile.username}?preview=true"
      refute html =~ "embed=1"
      assert html =~ ~s(title="Booking page preview")
    end

    test "tears the iframe down on close so a reopen reflects the latest theme", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding_with_calendar(conn)
      view = goto_choose_theme(view)

      view |> element("button[phx-click='preview_booking_page']") |> render_click()

      closed =
        view
        |> element("#onboarding-theme-preview button[aria-label='Close modal']")
        |> render_click()

      # No iframe remains, so the next open loads a fresh frame (current theme).
      refute closed =~ ~s(title="Booking page preview")
    end
  end

  describe "buffer step preview" do
    test "shows the buffer as a labelled gap, not a slot", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      view = navigate_to_scheduling_steps(view)

      assert render(view) =~ "buffer between meetings"
    end
  end

  describe "ready step" do
    test "offers only the dashboard button, no redundant link", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)

      view
      |> navigate_to_minimum_notice_step()
      |> element("button[phx-click='next_step']")
      |> render_click()

      html = render(view)
      assert html =~ "Go to dashboard"
      refute html =~ "explore your dashboard first"
    end
  end

  describe "colour scheme selection" do
    test "tints the preview and persists the choice", %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding_with_calendar(conn)
      view = goto_choose_theme(view)

      html =
        view
        |> element("button[phx-value-scheme='purple']")
        |> render_click()

      # Preview is tinted with the purple scheme's primary colour.
      assert html =~ "#8b5cf6"

      {:ok, profile} = Profiles.get_or_create_profile(user.id)

      %{customization: customization} =
        ThemeCustomizations.initialize_customization(profile.id, profile.booking_theme)

      assert customization.color_scheme == "purple"
      # The colour change must not clobber the seeded video background.
      assert customization.background_type == "video"
    end
  end

  describe "video backgrounds" do
    test "seeds every theme with a random video background once a calendar is connected",
         %{conn: conn} do
      {:ok, _view, _html, user} = setup_onboarding_with_calendar(conn)
      {:ok, profile} = Profiles.get_or_create_profile(user.id)

      for {_name, theme_id} <- ThemeInfo.theme_options() do
        customization = ThemeCustomizations.get_by_profile_and_theme(profile.id, theme_id)
        assert customization.background_type == "video"
        assert String.starts_with?(customization.background_value, "preset:")
      end
    end

    test "does not seed a video background when no calendar is connected", %{conn: conn} do
      {:ok, _view, _html, user} = setup_onboarding(conn)
      {:ok, profile} = Profiles.get_or_create_profile(user.id)

      customization = ThemeCustomizations.get_by_profile_and_theme(profile.id, "1")
      assert is_nil(customization)
    end

    test "does not overwrite a pre-existing video background on re-seed", %{conn: _conn} do
      # Pre-seed a known, deliberate background_value so we can verify it is
      # never clobbered if ensure_preview_video_backgrounds/2 is called again.
      user = insert(:user)
      {:ok, profile} = Profiles.get_or_create_profile(user.id)

      sentinel = "preset:idempotency_sentinel"

      ThemeCustomizations.upsert_theme_customization(profile.id, "1", %{
        "background_type" => "video",
        "background_value" => sentinel
      })

      # Calling the function again must hit the %{background_type: "video"} → :ok
      # skip branch and leave the sentinel unchanged.
      Onboarding.ensure_preview_video_backgrounds(profile, ["1"])

      customization = ThemeCustomizations.get_by_profile_and_theme(profile.id, "1")
      assert customization.background_value == sentinel
    end
  end

  describe "booking theme selection" do
    test "persists the chosen theme", %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding_with_calendar(conn)
      view = goto_choose_theme(view)

      view
      |> element("button[phx-value-theme='2']")
      |> render_click()

      {:ok, profile} = Profiles.get_or_create_profile(user.id)
      assert profile.booking_theme == "2"
    end
  end

  describe "avatar upload" do
    test "renders the upload control on the profile step", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      html = view |> goto_profile() |> render()

      assert html =~ "Upload photo"
      assert html =~ ~s(phx-drop-target)
    end

    test "stores the uploaded photo on the profile", %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding(conn)
      view = goto_profile(view)

      avatar =
        file_input(view, "#onboarding-avatar-form", :avatar, [
          %{name: "me.png", content: @png, type: "image/png"}
        ])

      render_upload(avatar, "me.png")

      {:ok, profile} = Profiles.get_or_create_profile(user.id)
      assert profile.avatar not in [nil, ""]
    end
  end
end
