defmodule TymeslotWeb.OnboardingLive.LivePreviewTest do
  use ExUnit.Case, async: true

  @moduletag :onboarding
  @moduletag :components

  import Phoenix.LiveViewTest

  alias Tymeslot.ThemeCustomizations.ThemeCustomizationSchema
  alias TymeslotWeb.OnboardingLive.LivePreview

  defp render_preview(settings) do
    render_component(&LivePreview.live_preview/1,
      current_step: :welcome,
      booking_theme: "1",
      theme_customization: %ThemeCustomizationSchema{theme_id: "1", settings: settings},
      booking_host: "tymeslot.test"
    )
  end

  test "draws with the theme's resolved colours, a custom seed included" do
    html =
      render_preview(%{
        "color_scheme" => "default",
        "custom_palette_seed" => "#123456",
        "background_type" => "gradient",
        "background_value" => "gradient_1"
      })

    assert html =~ "#123456"
    # The stored scheme's preset primary; the seed replaces the whole palette.
    refute html =~ "#06b6d4"
  end

  test "draws a preset scheme with that preset's colours" do
    html =
      render_preview(%{
        "color_scheme" => "sunset",
        "background_type" => "gradient",
        "background_value" => "gradient_1"
      })

    assert html =~ "#f97316"
  end
end
