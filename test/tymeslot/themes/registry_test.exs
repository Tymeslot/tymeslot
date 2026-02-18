defmodule Tymeslot.Themes.RegistryTest do
  @moduletag :themes
  use Tymeslot.DataCase, async: true
  alias Tymeslot.Themes.Registry

  test "delegates functions to TymeslotWeb.Themes.Core.Registry" do
  @moduletag :themes
    # Just test a few common ones to ensure delegation is correctly set up
    assert is_map(Registry.all_themes())
    assert is_map(Registry.active_themes())
    assert Registry.default_theme() != nil
    assert Registry.valid_theme_id?(Registry.default_theme_id())
  end
end
