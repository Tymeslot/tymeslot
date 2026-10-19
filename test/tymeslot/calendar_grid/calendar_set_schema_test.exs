defmodule Tymeslot.CalendarGrid.CalendarSetSchemaTest do
  @moduledoc "The calendar set changesets: name, position and members."

  use Tymeslot.DataCase, async: true

  @moduletag :calendar

  alias Ecto.Changeset
  alias Tymeslot.CalendarGrid.CalendarSetSchema

  defp changeset(attrs),
    do:
      CalendarSetSchema.changeset(
        %CalendarSetSchema{},
        Map.merge(%{user_id: 1, name: "Work", position: 1}, attrs)
      )

  test "a name is trimmed and loses null bytes" do
    changeset = changeset(%{name: "  Wo\u0000rk  "})
    assert changeset.valid?
    assert Changeset.get_change(changeset, :name) == "Work"
  end

  test "a blank name or one over 40 characters is refused" do
    refute changeset(%{name: "   "}).valid?
    refute changeset(%{name: "\u0000"}).valid?
    refute changeset(%{name: String.duplicate("a", 41)}).valid?
    assert changeset(%{name: String.duplicate("a", 40)}).valid?
  end

  test "the position is 1 to 9" do
    refute changeset(%{position: 0}).valid?
    refute changeset(%{position: 10}).valid?
    assert changeset(%{position: 9}).valid?
  end

  test "a member needs an integration; a missing calendar means the whole account" do
    refute changeset(%{members: [%{calendar_id: "work"}]}).valid?

    changeset = changeset(%{members: [%{integration_id: 4, calendar_id: nil}]})
    assert changeset.valid?

    assert [%{integration_id: 4, calendar_id: nil}] =
             Changeset.apply_changes(changeset).members
  end

  test "a calendar id is 1 to 255 characters and a set holds at most 200 members" do
    refute changeset(%{members: [%{integration_id: 4, calendar_id: ""}]}).valid?

    refute changeset(%{members: [%{integration_id: 4, calendar_id: String.duplicate("a", 256)}]}).valid?

    assert changeset(%{members: [%{integration_id: 4, calendar_id: String.duplicate("a", 255)}]}).valid?

    members = for n <- 1..201, do: %{integration_id: 4, calendar_id: "c#{n}"}
    refute changeset(%{members: members}).valid?
    assert changeset(%{members: Enum.take(members, 200)}).valid?

    set = %CalendarSetSchema{name: "Work", position: 1, members: []}
    refute CalendarSetSchema.members_changeset(set, members).valid?
  end

  test "members_changeset replaces the members alone" do
    set = %CalendarSetSchema{name: "Work", position: 1, members: []}

    changeset =
      CalendarSetSchema.members_changeset(set, [%{integration_id: 4, calendar_id: "work"}])

    assert changeset.valid?
    assert Map.keys(changeset.changes) == [:members]
  end
end
