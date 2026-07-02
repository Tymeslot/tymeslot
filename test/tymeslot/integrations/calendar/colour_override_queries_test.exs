defmodule Tymeslot.Integrations.Calendar.ColourOverrideQueriesTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :queries

  alias Tymeslot.Integrations.Calendar.ColourOverrideQueries, as: Q

  setup do
    user = insert(:user)
    integration = insert(:calendar_integration, user: user)
    %{user: user, integration: integration}
  end

  test "upserts and reads an external override", %{user: user, integration: integ} do
    assert {:ok, _} = Q.set_external(user.id, integ.id, "uid-1", "blueberry")
    assert Q.for_user(user.id) == %{{:external, integ.id, "uid-1"} => "blueberry"}
  end

  test "upsert replaces the colour on the same key", %{user: user, integration: integ} do
    {:ok, _} = Q.set_external(user.id, integ.id, "uid-1", "blueberry")
    {:ok, _} = Q.set_external(user.id, integ.id, "uid-1", "tomato")
    assert Q.for_user(user.id) == %{{:external, integ.id, "uid-1"} => "tomato"}
  end

  test "clear removes the override", %{user: user, integration: integ} do
    {:ok, _} = Q.set_external(user.id, integ.id, "uid-1", "blueberry")
    :ok = Q.clear_external(user.id, integ.id, "uid-1")
    assert Q.for_user(user.id) == %{}
  end

  test "set_meeting stores a booking override", %{user: user} do
    meeting = insert(:meeting)
    assert {:ok, _} = Q.set_meeting(user.id, meeting.id, "sage")
    assert Q.for_user(user.id) == %{{:meeting, meeting.id} => "sage"}
  end

  test "rejects an invalid palette key", %{user: user, integration: integ} do
    assert {:error, changeset} = Q.set_external(user.id, integ.id, "uid-1", "not-a-key")
    refute changeset.valid?
  end
end
