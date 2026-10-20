defmodule Tymeslot.CalendarGrid.ChangesCreateOutlookTest do
  @moduledoc """
  A repeat rule Outlook has no pattern for fails a create before anything
  is written: no provider call, no video room, nothing cached, and a reason
  the calendar can name (`:rule_not_supported_by_outlook`).
  """

  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :integration

  import Mox

  alias Tymeslot.CalendarGrid.Changes
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Repo

  setup :verify_on_exit!

  test "a repeat rule Outlook refuses fails the create, and nothing is written" do
    user = insert(:user)
    integration = insert(:calendar_integration, user: user, provider: "outlook", is_active: true)

    expect(Tymeslot.CalendarMock, :create_event, 0, fn _event_data, _context ->
      {:error, :rule_not_supported_by_outlook}
    end)

    payload = %{
      creating: %{
        title: "Review",
        integration_id: integration.id,
        calendar_id: "primary",
        attendees: [],
        recurrence_rule: "FREQ=MONTHLY;BYDAY=2TU,-1FR"
      },
      user_id: user.id,
      start_at: ~U[2026-04-14 09:00:00Z],
      end_at: ~U[2026-04-14 09:30:00Z]
    }

    assert {:error, %{reason: :rule_not_supported_by_outlook, retry: :not_queued}} =
             Changes.create_event(user.id, payload)

    assert Repo.all(ProviderCalendarEventSchema) == []
  end
end
