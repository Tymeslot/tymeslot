defmodule Tymeslot.CalendarGrid.EventCreationUnusableVideoTest do
  use Tymeslot.DataCase, async: false

  @moduletag :calendar

  import Mox
  import Tymeslot.Factory

  alias ExUnit.CaptureLog
  alias Tymeslot.CalendarGrid.EventCreation
  alias Tymeslot.Integrations.Calendar.CreatedEvent

  setup :verify_on_exit!

  describe "run_create_event/1 with a video integration the user cannot use" do
    # Another user's integration plans no room: the event is written without
    # one, no provider is called, and the refusal is logged.
    @tag :capture_log
    test "writes the event without a room and logs the refusal" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true)
      someone_elses = insert(:video_integration, provider: "mirotalk")

      expect(Tymeslot.CalendarMock, :create_event, fn _event_data, _context ->
        {:ok, CreatedEvent.new("no-room-uid")}
      end)

      payload = %{
        creating: %{
          title: "Solo",
          integration_id: integration.id,
          calendar_id: "primary",
          attendees: [],
          video_integration_id: someone_elses.id
        },
        user_id: user.id,
        start_at: ~U[2026-04-06 09:00:00Z],
        end_at: ~U[2026-04-06 09:30:00Z]
      }

      log =
        CaptureLog.capture_log(fn ->
          assert {:ok, result} = EventCreation.run_create_event(payload)
          assert is_nil(result[:meeting_url])
        end)

      assert log =~ "Video integration not usable; event created without a video room"
    end
  end
end
