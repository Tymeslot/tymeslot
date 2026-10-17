defmodule Tymeslot.CalendarGrid.EditGuardTest do
  @moduledoc """
  Whether an event may be changed from either calendar: the organiser's own
  integration, a calendar that takes writes, and not a Tymeslot booking.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :calendar

  import Tymeslot.Factory

  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.EditGuard

  setup do
    user = insert(:user)

    insert(:calendar_integration,
      user: user,
      provider: "google",
      is_active: true,
      calendar_list: [
        %{"id" => "work", "name" => "Work", "selected" => true},
        %{"id" => "shared", "name" => "Shared", "selected" => true, "read_only" => true}
      ]
    )

    # Loaded as the calendars load it, with the calendar list cast to entries.
    [integration] = CalendarGrid.list_active_integrations(user.id)
    %{user: user, integration: integration}
  end

  defp event(integration, calendar_id),
    do: %{uid: "u1", calendar_integration_id: integration.id, provider_calendar_id: calendar_id}

  test "an event on the organiser's writable calendar may be changed", %{integration: integration} do
    assert EditGuard.writable([integration], event(integration, "work")) == :ok
    assert EditGuard.editable?([integration], event(integration, "work"))
  end

  test "an event on a read-only calendar may not", %{integration: integration} do
    assert EditGuard.writable([integration], event(integration, "shared")) == {:error, :read_only}
    refute EditGuard.editable?([integration], event(integration, "shared"))
  end

  test "an event on someone else's integration may not", %{integration: integration} do
    other = insert(:calendar_integration, provider: "google")

    assert EditGuard.writable([integration], event(other, "work")) == {:error, :unauthorized}
  end

  test "a Tymeslot booking is changed from the booking, not here", %{integration: integration} do
    assert EditGuard.writable([integration], %{kind: :booking, id: "b1"}) == {:error, :booking}
  end

  test "check/3 passes a writable, unbooked event within the rate limit", %{
    user: user,
    integration: integration
  } do
    assert EditGuard.check(user.id, [integration], event(integration, "work")) == :ok
  end
end
