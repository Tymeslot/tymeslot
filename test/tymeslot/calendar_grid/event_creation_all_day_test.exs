defmodule Tymeslot.CalendarGrid.EventCreationAllDayTest do
  @moduledoc """
  Creating an all-day event with attendees from the grid: the invitation it
  sends has to carry the event's dates, since it has no instants to send.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :notifications
  @moduletag :integration

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.CalendarGrid.EventCreation
  alias Tymeslot.Integrations.Calendar.CreatedEvent
  alias Tymeslot.Workers.EmailWorker

  setup :verify_on_exit!

  describe "run_create_event/1 for an all-day event with attendees" do
    test "invites them with the event's dates rather than instants it does not have" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true)

      expect(Tymeslot.CalendarMock, :create_event, fn _event_data, _context ->
        {:ok, CreatedEvent.new("all-day-uid-1")}
      end)

      payload = %{
        creating: %{
          title: "Offsite",
          integration_id: integration.id,
          calendar_id: "primary",
          attendees: ["guest@example.com"],
          video_integration_id: nil,
          all_day: true
        },
        user_id: user.id,
        start_at: ~D[2026-10-12],
        end_at: ~D[2026-10-15]
      }

      assert {:ok, _result} = EventCreation.run_create_event(payload)

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_calendar_invitation",
          "attendee_email" => "guest@example.com",
          "event_all_day" => true,
          "event_start_date" => "2026-10-12",
          "event_end_date" => "2026-10-15"
        }
      )
    end
  end
end
