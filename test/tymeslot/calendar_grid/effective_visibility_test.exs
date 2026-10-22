defmodule Tymeslot.CalendarGrid.EffectiveVisibilityTest do
  @moduledoc """
  What a calendar set hides, and that without one the organiser's own
  hidden choices apply exactly as before.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :calendar

  import Tymeslot.Factory

  alias Tymeslot.CalendarGrid.CalendarSets
  alias Tymeslot.CalendarGrid.CalendarSetSchema
  alias Tymeslot.CalendarGrid.CalendarSetSchema.Member
  alias Tymeslot.CalendarGrid.EffectiveVisibility
  alias Tymeslot.Integrations.Calendar.Appearance
  alias Tymeslot.Integrations.Calendar.CalendarPreferencesQueries

  @work %{
    id: 1,
    calendar_list: [
      %{"id" => "work", "name" => "Work", "selected" => true},
      %{"id" => "family", "name" => "Family", "selected" => true},
      %{"id" => "archive", "name" => "Archive", "selected" => false}
    ]
  }
  @feed %{id: 2, calendar_list: []}
  @integrations [@work, @feed]

  defp set(members),
    do: %CalendarSetSchema{
      name: "Work",
      position: 1,
      members:
        Enum.map(members, fn {id, calendar} ->
          %Member{integration_id: id, calendar_id: calendar}
        end)
    }

  describe "resolve/4" do
    test "with no set, the organiser's own choices are the answer" do
      keys = MapSet.new([{1, "family"}])

      assert EffectiveVisibility.resolve([2], keys, @integrations, nil) ==
               %EffectiveVisibility{
                 hidden_integration_ids: [2],
                 hidden_calendar_keys: keys,
                 active_set: nil
               }
    end

    test "a set hides the synced calendars it does not list, whatever the organiser hid" do
      active = set([{1, "work"}, {2, nil}])

      result =
        EffectiveVisibility.resolve([1, 2], MapSet.new([{1, "work"}]), @integrations, active)

      assert result.hidden_integration_ids == []
      assert result.hidden_calendar_keys == MapSet.new([{1, "family"}])
      assert result.active_set == active
    end

    test "an account with no member is hidden whole" do
      result = EffectiveVisibility.resolve([], MapSet.new(), @integrations, set([{2, nil}]))

      assert result.hidden_integration_ids == [1]
      # Its calendars are keyed hidden too, so the rail never ticks one under an unticked account.
      assert result.hidden_calendar_keys == MapSet.new([{1, "work"}, {1, "family"}])
    end

    test "a whole-account member shows every calendar in the account" do
      result = EffectiveVisibility.resolve([], MapSet.new(), @integrations, set([{1, nil}]))

      assert result.hidden_integration_ids == [2]
      assert result.hidden_calendar_keys == MapSet.new()
    end

    test "a calendar connected after the set was saved stays hidden while it is active" do
      later = %{
        @work
        | calendar_list: @work.calendar_list ++ [%{"id" => "new", "selected" => true}]
      }

      result = EffectiveVisibility.resolve([], MapSet.new(), [later], set([{1, "work"}]))

      assert result.hidden_calendar_keys == MapSet.new([{1, "family"}, {1, "new"}])
    end
  end

  describe "resolve/4 with stale members" do
    test "a member naming an integration the organiser does not have is ignored" do
      with_stray = set([{1, "work"}, {99, "x"}, {99, nil}])
      without = set([{1, "work"}])

      assert EffectiveVisibility.resolve([], MapSet.new(), @integrations, with_stray) ==
               %{
                 EffectiveVisibility.resolve([], MapSet.new(), @integrations, without)
                 | active_set: with_stray
               }
    end

    test "an account whose members all name calendars it no longer syncs is hidden whole" do
      result =
        EffectiveVisibility.resolve([], MapSet.new(), @integrations, set([{1, "gone"}, {2, nil}]))

      assert result.hidden_integration_ids == [1]
      assert result.hidden_calendar_keys == MapSet.new([{1, "work"}, {1, "family"}])
    end
  end

  describe "reject/2" do
    test "drop what the set hides and never a booking" do
      result = EffectiveVisibility.resolve([], MapSet.new(), @integrations, set([{1, "work"}]))

      events = [
        %{id: "a", calendar_integration_id: 1, provider_calendar_id: "work"},
        %{id: "b", calendar_integration_id: 1, provider_calendar_id: "family"},
        %{id: "c", calendar_integration_id: 2, provider_calendar_id: "feed"},
        %{id: "booking-9", calendar_integration_id: nil, provider_calendar_id: nil}
      ]

      assert Enum.map(EffectiveVisibility.reject(events, result), & &1.id) == ["a", "booking-9"]
      assert result.hidden_integration_ids == [2]
    end
  end

  describe "for_user/1" do
    test "reads the stores and the active set from the database" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          is_active: true,
          calendar_list: [
            %{"id" => "work", "name" => "Work", "selected" => true},
            %{"id" => "family", "name" => "Family", "selected" => true}
          ]
        )

      {:ok, _appearance} = Appearance.set_hidden(user.id, integration.id, "work", true)

      assert EffectiveVisibility.for_user(user.id).hidden_calendar_keys ==
               MapSet.new([{integration.id, "work"}])

      {:ok, active} =
        CalendarSets.create(user.id, "Work", [
          %{integration_id: integration.id, calendar_id: "work"}
        ])

      {:ok, _set} = CalendarSets.activate(user.id, active.position)

      result = EffectiveVisibility.for_user(user.id)
      assert result.hidden_calendar_keys == MapSet.new([{integration.id, "family"}])
      assert result.active_set.id == active.id
      assert CalendarPreferencesQueries.get_or_create(user.id).hidden_integration_ids == []
    end
  end
end
