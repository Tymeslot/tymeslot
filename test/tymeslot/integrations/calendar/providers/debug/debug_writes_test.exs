defmodule Tymeslot.Integrations.Calendar.DebugCalendarProvider.WritesTest do
  @moduledoc """
  The debug calendar takes the calendar's writes through the real runtime
  path, the one every dev server uses, not only through the interactive
  stub: an edit and a delete reach its store.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :integration

  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.DebugCalendarProvider
  alias Tymeslot.Integrations.Calendar.DebugStore
  alias Tymeslot.Integrations.Calendar.Runtime.Operations

  setup do
    start_supervised!(DebugStore)
    DebugStore.set_pattern(:empty)

    user = insert(:user)
    integration = insert(:calendar_integration, user: user, provider: "debug", is_active: true)

    DebugStore.put_event(%{
      uid: "standup",
      summary: "Standup",
      all_day: false,
      start_time: ~U[2026-10-14 09:00:00Z],
      end_time: ~U[2026-10-14 09:30:00Z]
    })

    %{user: user, integration: integration}
  end

  test "an edit through the runtime reaches the store", %{user: user, integration: integration} do
    changes = %{
      summary: "Standup",
      all_day: false,
      start_time: ~U[2026-10-14 10:00:00Z],
      end_time: ~U[2026-10-14 10:30:00Z]
    }

    assert :ok = Operations.update_event("standup", changes, {integration.id, user.id})
    assert {:ok, %{start_time: ~U[2026-10-14 10:00:00Z]}} = DebugStore.fetch_event("standup")
  end

  test "a delete through the runtime removes the event", %{user: user, integration: integration} do
    assert :ok = Operations.delete_event("standup", {integration.id, user.id}, [])
    assert DebugStore.fetch_event("standup") == :error
  end

  test "outside development and test the provider gives no client" do
    previous = Application.get_env(:tymeslot, :environment)
    Application.put_env(:tymeslot, :environment, :prod)
    on_exit(fn -> Application.put_env(:tymeslot, :environment, previous) end)

    assert DebugCalendarProvider.build_booking_client_config(%{user_id: 1}) == nil
    assert DebugCalendarProvider.build_client_configs(%{user_id: 1}) == []
  end
end
