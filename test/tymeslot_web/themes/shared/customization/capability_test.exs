defmodule TymeslotWeb.Themes.Shared.Customization.CapabilityTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :utils

  alias TymeslotWeb.Themes.Shared.Customization.Capability

  test "delegates to Tymeslot.ThemeCustomizations.Capability" do
    # We use a known theme ID "1" or "2"
    assert is_map(Capability.get_customization_options("1"))
    assert is_map(Capability.get_capability_defaults("1"))
    assert is_boolean(Capability.supports_customization?("1", :background))

    # generate_css returns binary or error
    result = Capability.generate_css("1", %{})
    assert is_binary(result) or match?({:error, _}, result)
  end
end
