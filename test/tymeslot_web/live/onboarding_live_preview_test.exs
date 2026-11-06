defmodule TymeslotWeb.OnboardingLivePreviewTest do
  @moduledoc """
  Covers the onboarding live-preview panel and the personalisation controls:
  the profile step (avatar, name, booking link) and the `choose_theme` step
  (booking theme, colour scheme).

  These assert the user-visible journey: the right-hand mock reflects the
  organiser's in-progress data, the theme step cannot be reached without a
  calendar, and theme/colour selections persist and redraw the stage.
  """

  use TymeslotWeb.LiveCase, async: false
  @moduletag :onboarding

  import Phoenix.LiveViewTest
  import Tymeslot.Factory
  import TymeslotWeb.OnboardingTestHelpers

  alias Tymeslot.Onboarding
  alias Tymeslot.Profiles
  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.Themes.Catalog
  alias Tymeslot.Utils.UrlBuilder
  alias TymeslotWeb.Themes.Core.ThemeInfo

  # 1x1 transparent PNG — a real image so the avatar magic-byte validation passes.
  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
       )

  setup tags do
    {:ok, conn: setup_onboarding_session(tags.conn)}
  end

  defp host do
    String.replace(UrlBuilder.base_url(), ~r{^https?://}, "")
  end

  describe "live preview reflects in-progress profile data" do
    test "profile step preview reflects the typed name and booking link", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)

      html = fill_profile(view, "Ada Lovelace", "ada")

      # Preview-specific markup: the name and the joined link chip.
      assert html =~ "Ada Lovelace"

      assert view
             |> element(~s([data-role="stage-address"]))
             |> render()
             |> Floki.parse_fragment!()
             |> Floki.text() =~
               "#{host()}/ada"
    end
  end

  describe "live username validation" do
    test "flags a reserved username immediately while typing", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)

      html = fill_profile(view, "Ada Lovelace", "admin")

      assert html =~ "reserved"
    end

    test "flags an already-taken username immediately while typing", %{conn: conn} do
      insert(:profile, %{username: "takenslot"})

      {:ok, view, _html, _user} = setup_onboarding(conn)

      html = fill_profile(view, "Ada Lovelace", "takenslot")

      assert html =~ "Someone already has this link"
    end

    test "accepts an available username with no error", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)

      html = fill_profile(view, "Ada Lovelace", "ada-unique-handle")

      refute html =~ "reserved"
      refute html =~ "already has this link"
    end
  end

  describe "choose_theme step gating" do
    test "cannot be reached without a connected calendar", %{conn: conn} do
      {conn, user} = onboarding_conn(conn)
      insert(:profile, user: user, username: "nocal#{System.unique_integer([:positive])}")

      {:ok, view, _html} = live(conn, "/onboarding/choose_theme")
      html = render(view)

      refute html =~ "Your booking theme"
      assert has_element?(view, ".onboarding-provider-cards")
    end

    test "follows the meeting step once a calendar is connected", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding_with_calendar(conn)
      html = view |> navigate_to_theme_step() |> render()

      assert html =~ "Your booking theme"
    end
  end

  describe "preview reshapes to the chosen theme" do
    test "starts as Quill (calendar grid) and switches to Rhythm on selection", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding_with_calendar(conn)
      view = navigate_to_theme_step(view)

      # Quill's signature month-calendar grid is present by default.
      assert render(view) =~ ~s(data-preview-part="month")

      html =
        view
        |> element("button[phx-value-theme='2']")
        |> render_click()

      # Rhythm has no month grid — its body is the compact week strip + list.
      refute html =~ ~s(data-preview-part="month")
    end
  end

  describe "the look step and the stage" do
    test "selecting a story updates the theme and the stage", %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding_with_calendar(conn)
      view = navigate_to_theme_step(view)

      assert has_element?(view, "#onboarding-stage[data-theme='1']")

      view
      |> element("[data-testid='theme-story'][phx-value-theme='2']")
      |> render_click()

      {:ok, profile} = Profiles.get_or_create_profile(user.id)
      assert profile.booking_theme == "2"
      assert has_element?(view, "#onboarding-stage[data-theme='2']")
      refute has_element?(view, "#onboarding-stage[data-theme='1']")
      # The stage draws Rhythm: its backdrop behind the glass card, no month grid.
      assert has_element?(view, "#onboarding-stage [data-preview-part='backdrop']")
      refute has_element?(view, "#onboarding-stage [data-preview-part='month']")
    end

    test "the preview button is gone", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding_with_calendar(conn)
      html = view |> navigate_to_theme_step() |> render()

      assert html =~ "Your booking theme"
      refute has_element?(view, "[phx-click='preview_booking_page']")
      refute html =~ "Preview booking page"
      refute has_element?(view, "#onboarding-theme-preview")
    end
  end

  describe "a headline for a theme that introduces the host" do
    # The offered themes split by the catalogue fact the field follows.
    defp intro_theme_id do
      Enum.find_value(ThemeInfo.theme_options(), fn {_name, id} ->
        Catalog.shows_intro?(id) && id
      end)
    end

    defp plain_theme_id do
      Enum.find_value(ThemeInfo.theme_options(), fn {_name, id} ->
        !Catalog.shows_intro?(id) && id
      end)
    end

    test "choosing the theme offers the line; typing saves it and puts it under the name",
         %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding_with_calendar(conn)
      view = navigate_to_theme_step(view)
      refute has_element?(view, "#onboarding-headline-form")

      view
      |> element("[data-testid='theme-story'][phx-value-theme='#{intro_theme_id()}']")
      |> render_click()

      assert has_element?(view, "#onboarding-headline-form input#onboarding-headline")

      view
      |> form("#onboarding-headline-form",
        profile_intro: %{headline: "  Career coach for first-time managers "}
      )
      |> render_change()

      {:ok, profile} = Profiles.get_or_create_profile(user.id)
      assert profile.headline == "Career coach for first-time managers"

      assert view
             |> element("#onboarding-stage [data-role='preview-headline']")
             |> render() =~ "Career coach for first-time managers"

      # Clearing the line clears the headline, and Continue still moves on.
      view
      |> form("#onboarding-headline-form", profile_intro: %{headline: ""})
      |> render_change()

      {:ok, profile} = Profiles.get_or_create_profile(user.id)
      assert profile.headline == nil
      refute has_element?(view, "#onboarding-stage [data-role='preview-headline']")

      click_continue(view)
      assert has_element?(view, "#onboarding-stage[data-step='ready']")
    end

    test "a line past the cap is refused under the field and leaves the saved one",
         %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding_with_calendar(conn)
      view = navigate_to_theme_step(view)

      view
      |> element("[data-testid='theme-story'][phx-value-theme='#{intro_theme_id()}']")
      |> render_click()

      view
      |> form("#onboarding-headline-form", profile_intro: %{headline: "Coach"})
      |> render_change()

      html =
        view
        |> form("#onboarding-headline-form",
          profile_intro: %{headline: String.duplicate("a", 121)}
        )
        |> render_change()

      assert html =~ ~s(aria-invalid="true")
      {:ok, profile} = Profiles.get_or_create_profile(user.id)
      assert profile.headline == "Coach"
    end

    test "a theme that does not introduce the host has no field and no line on the stage",
         %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding_with_calendar(conn)
      {:ok, profile} = Profiles.get_or_create_profile(user.id)
      {:ok, _profile} = Profiles.update_intro(profile, %{"headline" => "Career coach"})
      view = navigate_to_theme_step(view)

      view
      |> element("[data-testid='theme-story'][phx-value-theme='#{plain_theme_id()}']")
      |> render_click()

      refute has_element?(view, "#onboarding-headline-form")
      refute has_element?(view, "#onboarding-stage [data-role='preview-headline']")
    end
  end

  describe "ready step" do
    test "offers only the dashboard button, no redundant link", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding_with_calendar(conn)

      html = view |> navigate_to_ready_step() |> render()
      assert html =~ "Go to dashboard"
      refute html =~ "explore your dashboard first"
    end
  end

  describe "colour scheme selection" do
    test "tints the preview and persists the choice", %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding_with_calendar(conn)
      view = navigate_to_theme_step(view)

      html =
        view
        |> element("button[phx-value-choice='purple']")
        |> render_click()

      # Preview is tinted with the purple scheme's primary colour.
      assert html =~ "#8b5cf6"

      {:ok, profile} = Profiles.get_or_create_profile(user.id)

      %{customization: customization} =
        ThemeCustomizations.initialize_customization(profile.id, profile.booking_theme)

      assert customization.settings["color_scheme"] == "purple"
      # The colour change must not clobber the seeded video background.
      assert customization.settings["background_type"] == "video"
    end

    test "offers Quill's schemes in the order the wizard has always shown", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding_with_calendar(conn)
      html = view |> navigate_to_theme_step() |> render()

      assert Regex.scan(~r/phx-value-choice="([^"]+)"/, html, capture: :all_but_first) ==
               Enum.map(~w(default turquoise purple sunset ocean forest rose monochrome), &[&1])
    end
  end

  describe "video backgrounds" do
    test "seeds every theme that can show video with a random video background once a calendar is connected",
         %{conn: conn} do
      {:ok, _view, _html, user} = setup_onboarding_with_calendar(conn)
      {:ok, profile} = Profiles.get_or_create_profile(user.id)

      theme_ids = Enum.map(ThemeInfo.theme_options(), fn {_name, id} -> id end)

      {with_video, without_video} =
        Enum.split_with(theme_ids, &ThemeCustomizations.supports_background?(&1, :video))

      assert with_video != []

      for theme_id <- with_video do
        customization = ThemeCustomizations.get_by_profile_and_theme(profile.id, theme_id)
        assert customization.settings["background_type"] == "video"
        assert String.starts_with?(customization.settings["background_value"], "preset:")
      end

      for theme_id <- without_video do
        refute match?(
                 %{settings: %{"background_type" => "video"}},
                 ThemeCustomizations.get_by_profile_and_theme(profile.id, theme_id)
               )
      end
    end

    test "does not seed a video background when no calendar is connected", %{conn: conn} do
      {:ok, _view, _html, user} = setup_onboarding(conn)
      {:ok, profile} = Profiles.get_or_create_profile(user.id)

      customization = ThemeCustomizations.get_by_profile_and_theme(profile.id, "1")
      assert is_nil(customization)
    end

    test "does not overwrite a pre-existing video background on re-seed", %{conn: _conn} do
      # Pre-seed an uploaded video, which no random preset can ever equal, to
      # verify an existing video background is never replaced when
      # ensure_preview_video_backgrounds/2 is called again.
      user = insert(:user)
      {:ok, profile} = Profiles.get_or_create_profile(user.id)

      {:ok, _seeded} =
        ThemeCustomizations.upsert_theme_customization(profile.id, "1", %{
          "background_type" => "video",
          "background_value" => "custom",
          "background_video_path" => "themes/#{profile.id}/1/videos/mine.mp4"
        })

      Onboarding.ensure_preview_video_backgrounds(profile, ["1"])

      customization = ThemeCustomizations.get_by_profile_and_theme(profile.id, "1")
      assert customization.settings["background_value"] == "custom"

      assert customization.settings["background_video_path"] ==
               "themes/#{profile.id}/1/videos/mine.mp4"
    end
  end

  describe "booking theme selection" do
    test "persists the chosen theme", %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding_with_calendar(conn)
      view = navigate_to_theme_step(view)

      view
      |> element("button[phx-value-theme='2']")
      |> render_click()

      {:ok, profile} = Profiles.get_or_create_profile(user.id)
      assert profile.booking_theme == "2"
    end
  end

  describe "theme stories" do
    test "the theme step opens with the stories and switches to every theme's look and back",
         %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding_with_calendar(conn)
      view = navigate_to_theme_step(view)

      assert render(view) =~ "Which of these sounds like you?"
      assert has_element?(view, "[data-testid='theme-story'][phx-value-theme='2']")

      html = view |> element("button[phx-click='show_all_themes']") |> render_click()

      refute html =~ "Which of these sounds like you?"
      refute has_element?(view, "[data-testid='theme-story']")
      assert has_element?(view, "button[phx-value-theme='2']")

      html = view |> element("button[phx-click='show_theme_stories']") |> render_click()

      assert html =~ "Which of these sounds like you?"
    end

    test "choosing a story saves its theme and reshapes the preview", %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding_with_calendar(conn)
      view = navigate_to_theme_step(view)

      html =
        view
        |> element("[data-testid='theme-story'][phx-value-theme='2']")
        |> render_click()

      {:ok, profile} = Profiles.get_or_create_profile(user.id)
      assert profile.booking_theme == "2"
      # Rhythm's preview has no month grid (see "preview reshapes to the chosen theme").
      refute html =~ ~s(data-preview-part="month")

      assert has_element?(
               view,
               "[data-testid='theme-story'][phx-value-theme='2'][aria-pressed='true']"
             )
    end

    test "a thumbnail picked from every theme's look saves its theme and stays shown across steps",
         %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding_with_calendar(conn)
      view = navigate_to_theme_step(view)

      view |> element("button[phx-click='show_all_themes']") |> render_click()
      view |> element("[data-testid='theme-thumbnail'][phx-value-theme='2']") |> render_click()

      {:ok, profile} = Profiles.get_or_create_profile(user.id)
      assert profile.booking_theme == "2"

      view |> element("button[phx-click='previous_step']") |> render_click()
      refute has_element?(view, "[data-testid='theme-thumbnail']")

      view |> element("button[phx-click='next_step']") |> render_click()

      assert has_element?(
               view,
               "[data-testid='theme-thumbnail'][phx-value-theme='2'][aria-pressed='true']"
             )

      refute has_element?(view, "[data-testid='theme-story']")
    end

    test "each picker groups its buttons under the question it asks", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding_with_calendar(conn)
      view = navigate_to_theme_step(view)

      assert has_element?(view, "#theme-story-question", "Which of these sounds like you?")

      assert has_element?(
               view,
               "[role='group'][aria-labelledby='theme-story-question'] [data-testid='theme-story']"
             )

      view |> element("button[phx-click='show_all_themes']") |> render_click()

      assert has_element?(view, "#theme-look-question", "Pick the look and feel")

      assert has_element?(
               view,
               "[role='group'][aria-labelledby='theme-look-question'] [data-testid='theme-thumbnail']"
             )
    end
  end

  describe "avatar upload" do
    test "renders the upload control on the profile step", %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)
      html = render(view)

      assert html =~ "Upload photo"
      assert html =~ ~s(phx-drop-target)
    end

    test "stores the uploaded photo on the profile", %{conn: conn} do
      {:ok, view, _html, user} = setup_onboarding(conn)

      avatar =
        file_input(view, "#onboarding-avatar-form", :avatar, [
          %{name: "me.png", content: @png, type: "image/png"}
        ])

      render_upload(avatar, "me.png")

      {:ok, profile} = Profiles.get_or_create_profile(user.id)
      assert profile.avatar not in [nil, ""]
    end

    test "without a photo the page shows the initials of the name being typed, then the photo",
         %{conn: conn} do
      {:ok, view, _html, _user} = setup_onboarding(conn)

      fill_profile(view, "Ada Lovelace", "ada")
      assert initials(view, "#onboarding-stage-scale [data-role='preview-initials']") == "AL"
      assert initials(view, "[data-role='avatar-initials']") == "AL"

      fill_profile(view, "Grace Hopper", "ada")
      assert initials(view, "#onboarding-stage-scale [data-role='preview-initials']") == "GH"

      view
      |> file_input("#onboarding-avatar-form", :avatar, [
        %{name: "me.png", content: @png, type: "image/png"}
      ])
      |> render_upload("me.png")

      refute has_element?(view, "[data-role='preview-initials']")
      refute has_element?(view, "[data-role='avatar-initials']")
      assert render(view) =~ "Change photo"
    end
  end

  defp initials(view, selector) do
    view
    |> element(selector)
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.text()
    |> String.trim()
  end
end
