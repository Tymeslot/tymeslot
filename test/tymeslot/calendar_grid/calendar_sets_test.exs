defmodule Tymeslot.CalendarGrid.CalendarSetsTest do
  @moduledoc """
  The calendar sets context: creating at the lowest free position up to
  nine, renaming, deleting, editing members, activating with an ownership
  check, and the member rules the rail's ticks use.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :calendar

  import Tymeslot.Factory

  alias Tymeslot.CalendarGrid.CalendarSets
  alias Tymeslot.CalendarGrid.EffectiveVisibility
  alias Tymeslot.Integrations.Calendar.CalendarPreferencesQueries

  @work_member %{integration_id: 1, calendar_id: "work"}

  setup do
    user = insert(:user)
    integration = insert(:calendar_integration, user: user, is_active: true)

    %{
      user: user,
      integration: integration,
      member: %{integration_id: integration.id, calendar_id: "work"}
    }
  end

  defp active_id(user),
    do: CalendarPreferencesQueries.get_or_create(user.id).active_calendar_set_id

  describe "create/3" do
    test "takes the lowest free position and keeps the members", %{user: user, member: member} do
      assert {:ok, first} = CalendarSets.create(user.id, "Work", [member])
      assert {:ok, second} = CalendarSets.create(user.id, "Family", [])
      assert {first.position, second.position} == {1, 2}
      assert [^member] = Enum.map(first.members, &Map.take(&1, [:integration_id, :calendar_id]))

      {:ok, _deleted} = CalendarSets.delete(user.id, 1)
      assert {:ok, %{position: 1}} = CalendarSets.create(user.id, "Again", [])
    end

    test "refuses a tenth set", %{user: user} do
      for n <- 1..9, do: {:ok, _set} = CalendarSets.create(user.id, "Set #{n}", [])
      assert CalendarSets.create(user.id, "Tenth", []) == {:error, :limit}
    end

    test "refuses a blank name", %{user: user} do
      assert {:error, %Ecto.Changeset{}} = CalendarSets.create(user.id, "  ", [])
      assert CalendarSets.list(user.id) == []
    end

    test "each organiser numbers their own sets", %{user: user} do
      {:ok, _theirs} = CalendarSets.create(insert(:user).id, "Theirs", [])
      assert {:ok, %{position: 1}} = CalendarSets.create(user.id, "Mine", [])
    end
  end

  describe "stored members" do
    test "never name an integration the organiser does not have", %{user: user, member: member} do
      foreign = insert(:calendar_integration, user: insert(:user), is_active: true)

      stray = [
        %{integration_id: foreign.id, calendar_id: "x"},
        %{integration_id: -1, calendar_id: nil}
      ]

      assert {:ok, set} = CalendarSets.create(user.id, "Work", stray ++ [member])
      assert [%{integration_id: id}] = set.members
      assert id == member.integration_id

      assert {:ok, %{members: []}} = CalendarSets.put_members(user.id, 1, stray)
    end

    test "refuse more than 200 members", %{user: user, member: member} do
      members = for n <- 1..201, do: %{member | calendar_id: "c#{n}"}

      assert {:error, %Ecto.Changeset{}} = CalendarSets.create(user.id, "Work", members)
    end
  end

  describe "rename/3, put_members/3 and delete/2" do
    test "change the organiser's own set", %{user: user, member: member} do
      {:ok, _set} = CalendarSets.create(user.id, "Work", [])

      assert {:ok, %{name: "Office"}} = CalendarSets.rename(user.id, 1, " Office ")

      assert {:ok, %{members: [%{calendar_id: "work"}]}} =
               CalendarSets.put_members(user.id, 1, [member])

      assert {:ok, %{position: 1}} = CalendarSets.delete(user.id, 1)
      assert CalendarSets.list(user.id) == []
    end

    test "answer not found for a position the organiser has no set on", %{user: user} do
      {:ok, _theirs} = CalendarSets.create(insert(:user).id, "Theirs", [])

      assert CalendarSets.rename(user.id, 1, "Mine") == {:error, :not_found}
      assert CalendarSets.put_members(user.id, 1, []) == {:error, :not_found}
      assert CalendarSets.delete(user.id, 1) == {:error, :not_found}
    end
  end

  describe "activate/2 and active/2" do
    test "names the active set on the preferences, and 0 clears it", %{user: user} do
      {:ok, set} = CalendarSets.create(user.id, "Work", [])

      assert {:ok, %{id: id}} = CalendarSets.activate(user.id, 1)
      assert id == set.id
      assert active_id(user) == set.id

      assert CalendarSets.active(user.id, CalendarPreferencesQueries.get_or_create(user.id)).id ==
               set.id

      assert CalendarSets.activate(user.id, 0) == {:ok, nil}
      assert active_id(user) == nil

      assert CalendarSets.active(user.id, CalendarPreferencesQueries.get_or_create(user.id)) ==
               nil
    end

    test "never activates another organiser's set", %{user: user} do
      {:ok, _theirs} = CalendarSets.create(insert(:user).id, "Theirs", [])

      assert CalendarSets.activate(user.id, 1) == {:error, :not_found}
      assert CalendarSets.activate(user.id, 12) == {:error, :not_found}
      assert active_id(user) == nil
    end

    test "preferences naming another organiser's set have no active set", %{user: user} do
      {:ok, theirs} = CalendarSets.create(insert(:user).id, "Theirs", [])

      {:ok, preferences} =
        CalendarPreferencesQueries.upsert(user.id, %{active_calendar_set_id: theirs.id})

      assert CalendarSets.active(user.id, preferences) == nil
      assert EffectiveVisibility.for_user(user.id).active_set == nil
    end

    test "deleting the active set leaves no set active", %{user: user} do
      {:ok, _set} = CalendarSets.create(user.id, "Work", [])
      {:ok, _active} = CalendarSets.activate(user.id, 1)

      {:ok, _deleted} = CalendarSets.delete(user.id, 1)

      assert active_id(user) == nil
    end

    test "the preferences refuse an id that names no set", %{user: user} do
      assert {:error, changeset} =
               CalendarPreferencesQueries.upsert(user.id, %{active_calendar_set_id: -1})

      assert {"does not exist", _opts} = changeset.errors[:active_calendar_set_id]
    end
  end

  describe "member rules" do
    @listed %{
      id: 1,
      calendar_list: [
        %{"id" => "work", "selected" => true},
        %{"id" => "family", "selected" => true}
      ]
    }
    @bare %{id: 2, calendar_list: []}

    test "members_from/2 takes what is shown now" do
      shown = %EffectiveVisibility{
        hidden_integration_ids: [],
        hidden_calendar_keys: MapSet.new([{1, "family"}])
      }

      assert CalendarSets.members_from([@listed, @bare], shown) == [
               %{integration_id: 1, calendar_id: "work"},
               %{integration_id: 2, calendar_id: nil}
             ]

      hidden = %EffectiveVisibility{
        hidden_integration_ids: [2],
        hidden_calendar_keys: MapSet.new()
      }

      assert CalendarSets.members_from([@bare], hidden) == []
    end

    test "toggle_account/2 removes a shown account and adds a hidden one whole" do
      assert CalendarSets.toggle_account([@work_member], @listed) == []

      assert CalendarSets.toggle_account([], @listed) == [
               %{integration_id: 1, calendar_id: "work"},
               %{integration_id: 1, calendar_id: "family"}
             ]

      assert CalendarSets.toggle_account([], @bare) == [%{integration_id: 2, calendar_id: nil}]
    end

    test "toggle_calendar/3 flips one calendar and splits a whole-account member" do
      assert CalendarSets.toggle_calendar([@work_member], @listed, "work") == []

      assert CalendarSets.toggle_calendar([], @listed, "family") == [
               %{integration_id: 1, calendar_id: "family"}
             ]

      assert CalendarSets.toggle_calendar(
               [%{integration_id: 1, calendar_id: nil}],
               @listed,
               "work"
             ) == [
               %{integration_id: 1, calendar_id: "family"}
             ]

      assert CalendarSets.toggle_calendar([], @listed, "not-listed") == []
    end
  end
end
