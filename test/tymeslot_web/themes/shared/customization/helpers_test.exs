defmodule TymeslotWeb.Themes.Shared.Customization.HelpersTest do
  @moduledoc """
  Covers `assign_theme_customization/3` — the per-tenant customisation entry
  point applied to every booking page mount. Without coverage here, a
  refactor could silently stop applying a tenant's colour/copy/background
  overrides.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :themes
  @moduletag :components

  import Tymeslot.Factory

  alias Phoenix.LiveView.Socket
  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema
  alias TymeslotWeb.Themes.Shared.Customization.Helpers

  defp socket, do: %Socket{assigns: %{__changed__: %{}}}

  describe "assign_theme_customization/3 — no persisted customisation" do
    test "falls back to defaults and marks has_custom_theme false" do
      profile = insert(:profile)

      updated = Helpers.assign_theme_customization(socket(), profile, "1")

      assert updated.assigns.has_custom_theme == false

      assert %ThemeCustomizationSchema{
               profile_id: nil,
               theme_id: "1",
               color_scheme: "default",
               background_type: "gradient",
               background_value: "gradient_1"
             } = updated.assigns.theme_customization

      assert updated.assigns.custom_css =~ "--theme-background: linear-gradient("
      assert %{color: _color, background: _background} = updated.assigns.customization_options
    end
  end

  describe "assign_theme_customization/3 — persisted customisation" do
    test "loads the tenant's customisation and marks has_custom_theme true" do
      profile = insert(:profile)

      _customization =
        insert(:theme_customization,
          profile: profile,
          theme_id: "1",
          color_scheme: "default",
          background_type: "gradient",
          background_value: "gradient_1"
        )

      updated = Helpers.assign_theme_customization(socket(), profile, "1")

      assert updated.assigns.has_custom_theme == true
      assert updated.assigns.theme_customization.color_scheme == "default"
      assert updated.assigns.theme_customization.background_value == "gradient_1"
    end

    test "is theme-scoped — a customisation for theme 1 does not leak to theme 2" do
      profile = insert(:profile)

      _theme_one =
        insert(:theme_customization, profile: profile, theme_id: "1", color_scheme: "default")

      updated_two = Helpers.assign_theme_customization(socket(), profile, "2")

      assert updated_two.assigns.has_custom_theme == false
    end
  end

  describe "get_background_style/1" do
    test "returns empty string for nil" do
      assert Helpers.get_background_style(nil) == ""
    end

    test "returns empty string when background type is video (rendered via media tag instead)" do
      profile = insert(:profile)

      customization =
        insert(:theme_customization,
          profile: profile,
          theme_id: "1",
          background_type: "video",
          background_value: "https://example.com/bg.mp4"
        )

      assert Helpers.get_background_style(customization) == ""
    end

    test "produces a gradient inline style when background_type is gradient" do
      profile = insert(:profile)

      customization =
        insert(:theme_customization,
          profile: profile,
          theme_id: "1",
          background_type: "gradient",
          background_value: "gradient_1"
        )

      style = Helpers.get_background_style(customization)

      assert style == "background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);"
    end
  end
end
