defmodule Tymeslot.Themes.CatalogTest do
  use Tymeslot.DataCase, async: true

  @moduletag :themes

  alias Tymeslot.Themes.Catalog

  test "exposes theme facts as the domain source of truth" do
    assert is_map(Catalog.all())
    assert is_map(Catalog.active())
    assert Catalog.default() != nil
    assert Catalog.valid_id?(Catalog.default_id())
  end
end
