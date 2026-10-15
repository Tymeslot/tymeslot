defmodule Tymeslot.CalendarGrid.EventCreationMonthEndTest do
  @moduledoc """
  A monthly series on a day some months lack is refused for Outlook, which
  would move those months' events to their last day (see
  `Outlook.RecurrenceConverter`), before anything is written or a video room
  is made. `Calendar.Events` points at `Tymeslot.CalendarMock`.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :integration

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.CalendarGrid.EventCreation
  alias Tymeslot.Integrations.Calendar.CreatedEvent

  setup :verify_on_exit!

  describe "run_create_event/1 — a monthly series on a day some months lack" do
    defp month_end_payload(integration, user) do
      %{
        creating: %{
          title: "Month-end close",
          integration_id: integration.id,
          calendar_id: "primary",
          attendees: [],
          recurrence_rule: "FREQ=MONTHLY"
        },
        user_id: user.id,
        start_at: ~U[2026-01-31 09:00:00Z],
        end_at: ~U[2026-01-31 10:00:00Z]
      }
    end

    # No `create_event` expectation: a write reaching the calendar fails the test.
    test "is refused for Outlook before anything is written" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, provider: "outlook")

      assert EventCreation.run_create_event(month_end_payload(integration, user)) ==
               {:error, %{reason: :day_missing_in_some_months, retry: :not_queued}}
    end

    test "is written to a calendar that skips the short months itself" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, provider: "caldav")

      expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
        assert event_data.recurrence_rule == "FREQ=MONTHLY"
        {:ok, CreatedEvent.new(event_data.uid)}
      end)

      assert {:ok, _result} = EventCreation.run_create_event(month_end_payload(integration, user))
    end
  end
end
