defmodule TymeslotWeb.ThemeTestMatrixTest do
  @moduledoc """
  The shared flow suites test exactly the themes `ThemeTestMatrix` lists, so a
  theme missing from it would ship untested by all of them without a single
  red test. This is the red test.
  """
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias Tymeslot.ThemeCustomizations.QuillSpec
  alias Tymeslot.Themes.Catalog
  alias TymeslotWeb.ThemeTestMatrix

  test "has an entry for every catalogue theme, and for nothing else" do
    assert Enum.sort(ThemeTestMatrix.registered_ids()) == Enum.sort(Catalog.valid_ids())
  end

  test "agrees with the catalogue on each theme's key and slug" do
    entries = ThemeTestMatrix.registered()
    assert entries != []

    for entry <- entries do
      assert Catalog.id_to_key(entry.id) == {:ok, entry.key}
      assert entry.slug == Atom.to_string(entry.key)
    end
  end

  test "lists themes in numeric id order" do
    ids = ThemeTestMatrix.registered_ids()
    assert ids == Enum.sort_by(ids, &String.to_integer/1)
  end

  # A fixture entry skips every flow suite, so only a theme the test config
  # registers may be one: a shipped theme marked as a fixture would ship
  # without its flows tested.
  test "marks as fixtures exactly the themes the test config registers" do
    fixture_ids = for entry <- ThemeTestMatrix.registered(), entry.fixture, do: entry.id
    extra_ids = Enum.map(Application.get_env(:tymeslot, :extra_themes, []), & &1.id)

    assert fixture_ids != []
    assert Enum.sort(fixture_ids) == Enum.sort(extra_ids)
  end

  test "hands the flow suites the shipped themes only" do
    assert ThemeTestMatrix.all() != []
    assert Enum.filter(ThemeTestMatrix.all(), & &1.fixture) == []
    assert ThemeTestMatrix.ids() == Enum.map(ThemeTestMatrix.all(), & &1.id)
  end

  test "ids_where/1 keeps the shipped themes whose spec passes, in id order" do
    assert ThemeTestMatrix.ids_where(fn _spec -> true end) == ThemeTestMatrix.ids()
    assert ThemeTestMatrix.ids_where(fn _spec -> false end) == []
    assert ThemeTestMatrix.ids_where(&(&1 == QuillSpec)) == ["1"]
  end

  test "says how each theme's schedule step picks a time" do
    for entry <- ThemeTestMatrix.registered() do
      assert entry.schedule_view in [:calendar, :week_grid],
             "#{entry.name} has no schedule_view (:calendar or :week_grid)"
    end
  end

  test "says which journey each theme walks" do
    for entry <- ThemeTestMatrix.registered() do
      assert Map.get(entry, :journey) in [:classic, :custom],
             "#{entry.name} has no journey (:classic or :custom)"
    end
  end
end
