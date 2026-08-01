defmodule TymeslotWeb.Themes.Shared.Customization.CapabilityTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :utils

  alias TymeslotWeb.Themes.Shared.Customization.Capability

  test "delegates to Tymeslot.ThemeCustomizations.Capability" do
    # Theme ID "1" is Quill, which supports both colour and background overrides.
    assert %{color: _color, background: _background} = Capability.get_customization_options("1")

    assert Capability.get_capability_defaults("1") == %{
             "background_type" => "gradient",
             "background_value" => "gradient_1",
             "color_scheme" => "default"
           }

    assert Capability.supports_customization?("1", :background) == true

    # An empty customisation map carries no overrides, so no CSS is emitted.
    assert Capability.generate_css("1", %{}) == ""
  end
end
