defmodule TymeslotWeb.Live.Themes.ThemeCustomizationIntegrationTest do
  use TymeslotWeb.ConnCase, async: false
  @moduletag :utils

  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.ThemeCustomizations.Options.Palette
  alias Tymeslot.ThemeCustomizations.Presets
  alias Tymeslot.ThemeCustomizations.Specs
  alias TymeslotWeb.ThemeTestMatrix

  describe "theme customization application" do
    setup tags do
      Mox.set_mox_from_context(tags)
      TestMocks.setup_calendar_mocks()

      user = insert(:user)
      profile = insert(:profile, user: user, username: "customized-user")
      insert(:calendar_integration, user: user, is_active: true)
      insert(:meeting_type, user: user, name: "Quick Chat", duration_minutes: 30)

      %{user: user, profile: profile}
    end

    test "applies custom color scheme to Quill theme", %{conn: conn, profile: profile} do
      # Set Quill theme
      profile = Repo.update!(Changeset.change(profile, %{booking_theme: "1"}))

      # Create customization with a specific color scheme
      color_scheme = "purple"
      scheme_def = Presets.get_color_schemes()[color_scheme]
      primary_color = scheme_def.colors.primary

      {:ok, _customization} =
        ThemeCustomizations.create_theme_customization(profile.id, "1", %{
          "color_scheme" => color_scheme,
          "background_type" => "color",
          "background_value" => "#123456"
        })

      {:ok, _view, html} = live(conn, ~p"/#{profile.username}")

      # Check if CSS variables from the "purple" scheme are present in the style tag
      assert html =~ "--theme-primary: #{primary_color}"
      assert html =~ "--theme-background: #123456"

      # One override block, outranking the theme's own :root defaults, with
      # the palette's background under its own name.
      assert html =~ ":root:root {"
      assert html =~ "--theme-canvas: #1e1b4b;"

      # For Quill, the background color should be in the main-gradient div style
      assert html =~ "background-color: #123456"
    end

    test "applies custom gradient to Rhythm theme", %{conn: conn, profile: profile} do
      # Set Rhythm theme
      profile = Repo.update!(Changeset.change(profile, %{booking_theme: "2"}))

      # Create customization with a gradient
      gradient_id = "gradient_2"
      gradient_val = Presets.get_gradient_presets()[gradient_id].value

      {:ok, _customization} =
        ThemeCustomizations.create_theme_customization(profile.id, "2", %{
          "color_scheme" => "default",
          "background_type" => "gradient",
          "background_value" => gradient_id
        })

      {:ok, _view, html} = live(conn, ~p"/#{profile.username}")

      # Check for the gradient CSS in the root variables
      assert html =~ "--theme-background: #{gradient_val}"
    end

    test "applies video background to Rhythm theme", %{conn: conn, profile: profile} do
      # Set Rhythm theme
      profile = Repo.update!(Changeset.change(profile, %{booking_theme: "2"}))

      # Create customization with a video
      {:ok, _customization} =
        ThemeCustomizations.create_theme_customization(profile.id, "2", %{
          "color_scheme" => "default",
          "background_type" => "video",
          "background_value" => "preset:rhythm-default"
        })

      {:ok, _view, html} = live(conn, ~p"/#{profile.username}")

      # Check for video tag
      assert html =~ "<video"
      # Just check for the filename part since multiple formats are generated
      assert html =~ "rhythm-background-desktop"
      # Poster should use the preset poster image
      assert html =~ ~s(poster="/images/ui/posters/rhythm-background-poster.jpg")
    end

    test "a preset image renders under the kept path in every theme that offers images", %{
      conn: conn,
      profile: profile
    } do
      image_themes = ThemeTestMatrix.ids_where(&Specs.supports_background?(&1, :image))

      assert image_themes != []

      for theme_id <- image_themes do
        Repo.update!(Changeset.change(profile, %{booking_theme: theme_id}))

        {:ok, _customization} =
          ThemeCustomizations.upsert_theme_customization(profile.id, theme_id, %{
            "background_type" => "image",
            "background_value" => "preset:ocean-sunset"
          })

        {:ok, _view, html} = live(conn, ~p"/#{profile.username}")

        assert html =~ "url(&#39;/images/themes/backgrounds/ocean-sunset.webp&#39;)",
               "theme #{theme_id} did not render the preset image"
      end
    end

    test "an uploaded video renders its variants with the original as the last source",
         %{conn: conn, profile: profile} do
      Repo.update!(Changeset.change(profile, %{booking_theme: "2"}))

      {:ok, _customization} =
        ThemeCustomizations.upsert_theme_customization(profile.id, "2", %{
          "background_type" => "video",
          "background_value" => "custom",
          "background_video_path" => "themes/#{profile.id}/2/videos/clip.mp4"
        })

      {:ok, _view, html} = live(conn, ~p"/#{profile.username}")

      assert html =~ ~s(src="/uploads/themes/#{profile.id}/2/videos/clip-desktop.webm")

      assert html =~
               ~s(<source src="/uploads/themes/#{profile.id}/2/videos/clip.mp4" type="video/mp4")
    end

    test "custom palette seed flows through to booking page CSS variables",
         %{conn: conn, profile: profile} do
      # Set Quill theme (theme 1 supports custom colours)
      profile = Repo.update!(Changeset.change(profile, %{booking_theme: "1"}))

      seed = "#ff6b35"

      # Store a custom seed via the public API (apply_option)
      {:ok, _customization} =
        ThemeCustomizations.apply_option(profile.id, "1", :palette, %{
          "field" => "seed",
          "value" => seed
        })

      # Load the public booking page
      {:ok, _view, html} = live(conn, ~p"/#{profile.username}")

      # The derived primary colour equals the seed — verify the CSS variable is present
      assert html =~ "--theme-primary: #{seed}"
    end

    test "?primary-color= overrides the saved primary for that page view only, in every theme",
         %{conn: conn, profile: profile} do
      for theme_id <- ThemeTestMatrix.ids() do
        Repo.update!(Changeset.change(profile, %{booking_theme: theme_id}))
        scheme = saved_scheme(theme_id)

        {:ok, customization} =
          ThemeCustomizations.upsert_theme_customization(profile.id, theme_id, %{
            "color_scheme" => scheme
          })

        saved_primary =
          ThemeCustomizations.tokens(theme_id, customization).vars["--theme-primary"]

        refute saved_primary == "#e11d48"

        {:ok, _view, html} = live(conn, "/#{profile.username}?primary-color=%23e11d48")
        assert html =~ "--theme-primary: #e11d48;", "theme #{theme_id} ignored the override"

        {:ok, _view, plain} = live(conn, "/#{profile.username}")
        assert plain =~ "--theme-primary: #{saved_primary};"

        assert ThemeCustomizations.get_by_profile_and_theme(profile.id, theme_id).settings[
                 "color_scheme"
               ] == scheme
      end
    end

    test "an invalid ?primary-color= is ignored", %{conn: conn, profile: profile} do
      {:ok, _view, html} = live(conn, "/#{profile.username}?primary-color=red")

      refute html =~ "--theme-primary: red"
      assert html =~ "--theme-primary: #06b6d4;"
    end

    test "an embedded page honours the override", %{conn: conn, profile: profile} do
      Repo.update!(Changeset.change(profile, %{allowed_embed_domains: ["embedder.test"]}))

      conn = put_req_header(conn, "referer", "https://embedder.test/page")

      {:ok, view, html} = live(conn, "/#{profile.username}?embed=1&primary-color=%23e11d48")

      assert :sys.get_state(view.pid).socket.assigns[:embedded] == true
      assert html =~ "--theme-primary: #e11d48;"
    end
  end

  # A scheme the theme offers other than its default, so the saved choice is
  # visible on the page: "purple" where the theme has it, as this test has
  # always saved for Quill and Rhythm.
  defp saved_scheme(theme_id) do
    spec = Specs.for_theme(theme_id)
    schemes = Specs.group(spec, Palette).schemes

    if "purple" in schemes,
      do: "purple",
      else: Enum.find(schemes, &(&1 != spec.defaults()[:color_scheme]))
  end
end
