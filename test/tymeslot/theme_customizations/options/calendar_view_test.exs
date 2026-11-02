defmodule Tymeslot.ThemeCustomizations.Options.CalendarViewTest do
  use ExUnit.Case, async: true

  @moduletag :themes
  @moduletag :unit

  alias Ecto.Changeset
  alias Tymeslot.ThemeCustomizations.OptionGroup
  alias Tymeslot.ThemeCustomizations.Options.CalendarView

  @group %{key: :calendar_view, module: CalendarView, default: "month"}
  @acc %{vars: %{}, dark_vars: %{"--theme-canvas" => "#0e0e10"}}

  defp changeset(attrs),
    do:
      {%{}, CalendarView.types()}
      |> Changeset.change()
      |> CalendarView.changeset(attrs, @group)

  test "the changeset accepts month and week, and nothing else" do
    assert changeset(%{"calendar_view" => "month"}).valid?
    assert changeset(%{"calendar_view" => "week"}).valid?
    refute changeset(%{"calendar_view" => "year"}).valid?
  end

  test "the choices are a month, then a week" do
    assert CalendarView.choices() == ~w(month week)
  end

  test "a stored choice wins, anything else is the group's default" do
    assert CalendarView.choice(%{"calendar_view" => "week"}, @group) == "week"
    assert CalendarView.choice(%{}, @group) == "month"
    assert CalendarView.choice(%{"calendar_view" => "year"}, @group) == "month"
    assert CalendarView.choice(%{}, %{@group | default: "week"}) == "week"
  end

  test "a choice writes the setting" do
    assert CalendarView.changes("calendar_view", "week", @group) ==
             {:ok, %{"calendar_view" => "week"}}

    assert CalendarView.changes("view", "week", @group) == :error
  end

  test "the choice is put into the media, and no custom property is added" do
    assert OptionGroup.media(%{"calendar_view" => "week"}, @group) == %{calendar_view: "week"}
    assert OptionGroup.media(%{}, @group) == %{calendar_view: "month"}
    assert OptionGroup.media(%{}, %{@group | default: "week"}) == %{calendar_view: "week"}

    assert OptionGroup.tokens(%{"calendar_view" => "week"}, %{}, @acc, @group) == @acc
  end
end
