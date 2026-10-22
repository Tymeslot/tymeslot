defmodule Tymeslot.CalendarGrid.LayerPreferencesTest do
  @moduledoc """
  The bookable layer's saved choices: which meeting types it can show, which
  one it shows, and that only the organiser's own active types can be chosen.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :calendar

  import Tymeslot.Factory

  alias Tymeslot.CalendarGrid.LayerPreferences
  alias Tymeslot.Integrations.Calendar.CalendarPreferencesQueries
  alias Tymeslot.Repo

  setup do
    user = insert(:user)
    workshop = insert(:meeting_type, user: user, name: "Workshop", sort_order: 2)
    intro = insert(:meeting_type, user: user, name: "Intro call", sort_order: 1)
    %{user: user, workshop: workshop, intro: intro}
  end

  describe "meeting_types/1" do
    test "lists the active, unarchived types in the organiser's order", %{
      user: user,
      workshop: workshop,
      intro: intro
    } do
      insert(:meeting_type, user: user, name: "Paused", is_active: false, sort_order: 0)
      insert(:meeting_type, user: user, name: "Old", is_archived: true, sort_order: 0)
      insert(:meeting_type, name: "Someone else's", sort_order: 0)

      assert LayerPreferences.meeting_types(user.id) == [
               %{id: intro.id, name: "Intro call", duration: 30},
               %{id: workshop.id, name: "Workshop", duration: 30}
             ]
    end
  end

  # A fixed-date type's sessions are joined, never started: it has no
  # bookable times, so the layer would open empty on it.
  describe "fixed-date types" do
    setup %{user: user} do
      fixed =
        insert(:meeting_type,
          user: user,
          name: "Workshop series",
          sort_order: 0,
          fixed_dates: true,
          max_participants: 8
        )

      %{fixed: fixed}
    end

    test "are not offered, so the layer never falls back to one", %{
      user: user,
      intro: intro,
      fixed: fixed
    } do
      choices = LayerPreferences.meeting_types(user.id)

      refute Enum.any?(choices, &(&1.id == fixed.id))

      assert LayerPreferences.meeting_type(%{bookable_meeting_type_id: nil}, choices).id ==
               intro.id
    end

    test "a stored choice of one shows the first type instead", %{
      user: user,
      intro: intro,
      fixed: fixed
    } do
      choices = LayerPreferences.meeting_types(user.id)

      assert LayerPreferences.meeting_type(%{bookable_meeting_type_id: fixed.id}, choices).id ==
               intro.id
    end

    test "cannot be chosen", %{user: user, fixed: fixed} do
      assert LayerPreferences.choose_meeting_type(user.id, fixed.id) == {:error, :not_found}
    end
  end

  describe "meeting_type/2" do
    test "is the chosen type while it can be shown", %{user: user, workshop: workshop} do
      choices = LayerPreferences.meeting_types(user.id)

      assert LayerPreferences.meeting_type(%{bookable_meeting_type_id: workshop.id}, choices) ==
               %{id: workshop.id, name: "Workshop", duration: 30}
    end

    test "falls back to the first type when none is chosen or the choice is gone", %{
      user: user,
      intro: intro
    } do
      choices = LayerPreferences.meeting_types(user.id)

      assert LayerPreferences.meeting_type(%{bookable_meeting_type_id: nil}, choices).id ==
               intro.id

      assert LayerPreferences.meeting_type(%{bookable_meeting_type_id: -1}, choices).id ==
               intro.id
    end

    test "is nil with no types to show" do
      assert LayerPreferences.meeting_type(%{bookable_meeting_type_id: nil}, []) == nil
    end
  end

  test "the layer is on for an organiser who never chose", %{user: user} do
    assert CalendarPreferencesQueries.get_or_create(user.id).bookable_layer
  end

  test "set_layer/2 saves the switch", %{user: user} do
    assert {:ok, _preferences} = LayerPreferences.set_layer(user.id, false)
    refute CalendarPreferencesQueries.get_or_create(user.id).bookable_layer
  end

  describe "choose_meeting_type/2" do
    test "saves one of the organiser's own types", %{user: user, workshop: workshop} do
      assert {:ok, %{id: id, name: "Workshop", duration: 30}} =
               LayerPreferences.choose_meeting_type(user.id, to_string(workshop.id))

      assert id == workshop.id

      assert CalendarPreferencesQueries.get_or_create(user.id).bookable_meeting_type_id ==
               workshop.id
    end

    test "refuses another organiser's type, an archived one and garbage", %{user: user} do
      theirs = insert(:meeting_type, name: "Theirs")
      archived = insert(:meeting_type, user: user, is_archived: true)

      for id <- [theirs.id, to_string(archived.id), "12abc", nil] do
        assert LayerPreferences.choose_meeting_type(user.id, id) == {:error, :not_found}
      end

      assert CalendarPreferencesQueries.get_or_create(user.id).bookable_meeting_type_id == nil
    end

    test "deleting the chosen type clears the choice", %{user: user, workshop: workshop} do
      {:ok, _choice} = LayerPreferences.choose_meeting_type(user.id, workshop.id)

      Repo.delete!(workshop)

      assert CalendarPreferencesQueries.get_or_create(user.id).bookable_meeting_type_id == nil
    end
  end
end
