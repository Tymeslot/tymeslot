defmodule Tymeslot.Integrations.Calendar.UserIdsWithActiveCalendarTest do
  use Tymeslot.DataCase, async: true

  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar

  test "returns, of the given users, those with an active calendar, once each" do
    two = insert(:user)
    insert(:calendar_integration, user: two)
    insert(:calendar_integration, user: two)
    paused = insert(:user)
    insert(:calendar_integration, user: paused, is_active: false)
    none = insert(:user)
    not_asked = insert(:user)
    insert(:calendar_integration, user: not_asked)

    assert Calendar.user_ids_with_active_calendar([two.id, paused.id, none.id]) == [two.id]
  end

  test "an empty list asks nothing" do
    assert Calendar.user_ids_with_active_calendar([]) == []
  end
end
