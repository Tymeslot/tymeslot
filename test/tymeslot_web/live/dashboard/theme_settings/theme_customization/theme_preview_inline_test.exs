defmodule TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.ThemePreviewInlineTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :utils

  import Phoenix.LiveViewTest
  alias TymeslotWeb.Dashboard.ThemeSettings.ThemeCustomization.ThemePreviewInline

  test "renders theme preview with CSS variables" do
    theme_id = "1"

    customization = %{
      "color_scheme" => "default",
      "background_type" => "gradient",
      "background_value" => "gradient_1"
    }

    html =
      render_component(&ThemePreviewInline.preview/1,
        theme_id: theme_id,
        customization: customization
      )

    # Basic content check
    assert html =~ "Theme Preview"
    assert html =~ "Primary"
    assert html =~ "Confirm"
    assert html =~ "Secondary"

    # Check for CSS variable generation/application
    assert html =~ "--theme-primary"
    assert html =~ "--theme-text"
    assert html =~ "--theme-background"
  end

  test "renders with custom class" do
    html =
      render_component(&ThemePreviewInline.preview/1,
        theme_id: "1",
        customization: %{},
        class: "custom-preview-class"
      )

    assert html =~ "custom-preview-class"
  end
end
