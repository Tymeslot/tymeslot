defmodule Tymeslot.Themes.CatalogTest do
  use Tymeslot.DataCase, async: true

  @moduletag :themes

  alias Tymeslot.Themes.Catalog

  test "exposes theme facts as the domain source of truth" do
    assert %{quill: %{key: :quill, id: "1"}, rhythm: %{key: :rhythm}} = Catalog.all()

    active = Catalog.active()
    assert Map.keys(active) == [:quill, :rhythm]
    assert Enum.all?(active, fn {_key, theme} -> theme.status == :active end)

    assert %{key: :quill, id: "1", status: :active} = Catalog.default()
    assert Catalog.valid_id?(Catalog.default_id())
  end
end
