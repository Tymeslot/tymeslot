defmodule Tymeslot.CalendarGrid.EventCreationLocationTest do
  @moduledoc """
  A plain event's location (`creating.location`) reaches the provider's
  own location field, and an event without one sends none.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :integration

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.CalendarGrid.EventCreation
  alias Tymeslot.Integrations.Calendar.CreatedEvent

  setup :verify_on_exit!

  setup do
    user = insert(:user)
    integration = insert(:calendar_integration, user: user, provider: "caldav", is_active: true)
    %{user: user, integration: integration}
  end

  defp payload(ctx, extra) do
    %{
      creating:
        Map.merge(
          %{
            title: "Workshop",
            integration_id: ctx.integration.id,
            calendar_id: nil,
            attendees: []
          },
          extra
        ),
      user_id: ctx.user.id,
      start_at: ~U[2026-12-07 09:00:00Z],
      end_at: ~U[2026-12-07 10:00:00Z]
    }
  end

  defp expect_create(assertion) do
    expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
      assertion.(event_data)
      {:ok, CreatedEvent.from_provider_event(%{uid: "uid-location", summary: event_data.summary})}
    end)
  end

  test "writes the location to the provider", ctx do
    expect_create(fn event_data -> assert event_data.location == "Room 4.12" end)

    assert {:ok, _result} =
             EventCreation.run_create_event(payload(ctx, %{location: "Room 4.12"}))
  end

  test "sends no location for an event without one", ctx do
    expect_create(fn event_data -> refute Map.has_key?(event_data, :location) end)

    assert {:ok, _result} = EventCreation.run_create_event(payload(ctx, %{location: nil}))
  end
end
