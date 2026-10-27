defmodule Tymeslot.Integrations.Calendar.CalDAV.BookingCancelDeleteTest do
  @moduledoc """
  Cancelling a booking whose event lives on a plain CalDAV calendar removes
  that event from the organiser's server.

  The journey runs from `Meetings.cancel_meeting/1` through the delete job it
  enqueues, `CalendarEventWorker`, `CalendarEventSync`, the `Events` dispatch
  to the production calendar implementation, client resolution and the
  CalDAV provider. Only the HTTP boundary is stubbed, and what it must see is
  a `DELETE` of the booking's event.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :bookings
  @moduletag :integration

  import Req.Test, only: [set_req_test_to_shared: 1]
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.Meetings
  alias Tymeslot.Workers.CalendarEventWorker

  @base_url "https://booking-cancel.example.com"
  @calendar_path "/calendars/user/personal/"
  @event_uid "booking-cancel-1@tymeslot.com"
  @href @calendar_path <> @event_uid <> ".ics"

  setup :set_req_test_to_shared

  setup do
    with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
    with_config(:tymeslot, :req_test_plug, {Req.Test, :tymeslot_http})
    # The suite points `:calendar_module` at a Mox double; this journey is
    # about what reaches the server, so the production implementation runs.
    with_config(:tymeslot, :calendar_module, Tymeslot.Integrations.Calendar.Runtime.Operations)

    user = insert(:user)

    integration =
      insert(:calendar_integration,
        user: user,
        provider: "caldav",
        base_url: @base_url,
        calendar_paths: [@calendar_path],
        default_booking_calendar_id: @calendar_path
      )

    insert(:profile, user: user, primary_calendar_integration_id: integration.id)

    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        calendar_integration_id: integration.id,
        calendar_path: @calendar_path,
        calendar_uid: @event_uid,
        start_time: ~U[2026-11-02 09:00:00Z],
        end_time: ~U[2026-11-02 09:30:00Z]
      )

    %{meeting: meeting}
  end

  test "cancelling the booking deletes its event on the CalDAV server", %{meeting: meeting} do
    test_pid = self()

    ReqTest.stub(:tymeslot_http, fn conn ->
      send(test_pid, {:request, conn.method, conn.request_path})
      Conn.resp(conn, 204, "")
    end)

    assert {:ok, _cancelled} = Meetings.cancel_meeting(meeting)

    args = %{"action" => "delete", "meeting_id" => meeting.id}
    assert_enqueued(worker: CalendarEventWorker, args: args)
    assert :ok = perform_job(CalendarEventWorker, args)

    assert_received {:request, "DELETE", @href}
  end
end
