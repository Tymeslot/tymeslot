defmodule TymeslotWeb.Live.Themes.ThemeCustomizationIntegrationTest do
  use TymeslotWeb.ConnCase, async: false
  @moduletag :utils

  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias Tymeslot.ThemeCustomizations
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema

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
      scheme_def = ThemeCustomizationSchema.color_scheme_definitions()[color_scheme]
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

      # For Quill, the background color should be in the main-gradient div style
      assert html =~ "background-color: #123456"
    end

    test "applies custom gradient to Rhythm theme", %{conn: conn, profile: profile} do
      # Set Rhythm theme
      profile = Repo.update!(Changeset.change(profile, %{booking_theme: "2"}))

      # Create customization with a gradient
      gradient_id = "gradient_2"
      gradient_val = ThemeCustomizationSchema.gradient_presets()[gradient_id].value

      {:ok, _customization} =
        ThemeCustomizations.create_theme_customization(profile.id, "2", %{
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
  end
end
