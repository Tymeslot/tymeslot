defmodule Tymeslot.Meetings.CalendarEventSyncReauthTest do
  use Tymeslot.DataCase, async: true

  @moduletag :meetings
  @moduletag :integration

  import Mox
  import Tymeslot.WorkerTestHelpers

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Meetings.CalendarEventSync

  setup :verify_on_exit!

  describe "update/2 on a connection the calendar no longer authorises" do
    test "flags the integration for reconnection" do
      %{integration: integration, meeting: meeting} = setup_calendar_scenario()

      expect(Tymeslot.CalendarMock, :update_event, fn _uid, _data, _ctx ->
        {:error, :unauthorized}
      end)

      assert {:error, :unauthorized} = CalendarEventSync.update(meeting.id, 1)
      assert Repo.get!(CalendarIntegrationSchema, integration.id).needs_reauth
    end
  end
end
