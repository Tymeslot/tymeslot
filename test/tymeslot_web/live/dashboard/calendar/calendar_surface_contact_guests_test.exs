defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceContactGuestsTest do
  @moduledoc """
  An event the calendar wrote to a server that would invite an `ATTENDEE`
  itself (Zimbra, cPanel) carries its guests as `CONTACT` lines. Once a sync
  has read it back into the cache, the calendar still knows who the guests
  are: deleting it asks whether to tell them and sends the guest the
  cancellation, and moving it says they have not been told.

  The sync runs through the real CalDAV worker against the shared HTTP stub,
  so the module is not async.
  """

  use TymeslotWeb.LiveCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :live
  @moduletag :integration

  import Mox
  import Tymeslot.CalDAVSyncTestFixtures, only: [caldav_report_xml: 2]
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Test.AttendeeEmailDelivery, only: [deliver_all: 1]
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Ecto.Changeset
  alias Plug.Conn
  alias Req.Test, as: ReqTest
  alias Tymeslot.Integrations.Calendar.ICalBuilder
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Repo
  alias Tymeslot.Workers.CalendarEventDeleteWorker
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.SyncCalDavCalendarWorker

  @path "/calendars/user/work/"
  @uid "planning-contact@tymeslot.com"

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup %{conn: conn} do
    context = owner(conn)
    ReqTest.set_req_test_to_shared()
    with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)

    integration =
      context.integration
      |> Changeset.change(
        provider: "caldav",
        caldav_sync_tier: 3,
        calendar_paths: [@path],
        calendar_list: [%{"id" => @path, "name" => "Work", "selected" => true}]
      )
      |> Repo.update!()

    stub_server(written_with_contact())

    assert :ok =
             perform_job(SyncCalDavCalendarWorker, %{
               "calendar_integration_id" => integration.id
             })

    {:ok, planning} = ProviderCalendarEventQueries.get_by_uid(integration.id, @uid)
    {:ok, lv, _html} = live(context.conn, ~p"/dashboard/calendar")

    Map.merge(context, %{integration: integration, lv: lv, id: "event-#{planning.id}"})
  end

  # The document as the calendar writes it in `CONTACT` mode, which the
  # server stores and hands back on the next sync.
  defp written_with_contact do
    ICalBuilder.build_simple_event(
      @uid,
      %{
        summary: "Planning",
        start_time: ~U[2026-10-15 13:00:00Z],
        end_time: ~U[2026-10-15 14:00:00Z],
        attendees: [%{email: "ada@example.com", display_name: "Ada Lovelace"}]
      },
      :contact
    )
  end

  defp stub_server(ical) do
    ReqTest.stub(:tymeslot_http, fn conn ->
      conn
      |> Conn.put_resp_header("content-type", "application/xml")
      |> Conn.send_resp(207, caldav_report_xml("#{@path}planning.ics", xml_escape(ical)))
    end)
  end

  defp xml_escape(text),
    do:
      text
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")

  defp canvas(lv, name, params),
    do: lv |> element("#calendar-canvas") |> render_hook(name, params)

  defp cancelled_to do
    [worker: EmailWorker]
    |> all_enqueued()
    |> Enum.filter(
      &(&1.args["action"] == "send_calendar_invitation" and &1.args["method"] == "cancel")
    )
    |> Enum.map(& &1.args["attendee_email"])
  end

  test "a sync of the document the calendar wrote keeps its guest", %{
    integration: integration
  } do
    refute written_with_contact() =~ "ATTENDEE"

    {:ok, planning} = ProviderCalendarEventQueries.get_by_uid(integration.id, @uid)
    assert [%{"email" => "ada@example.com"}] = Enum.map(planning.attendees, &stringify/1)
  end

  test "deleting it asks first, and telling the guest sends her the cancellation", %{
    lv: lv,
    id: id
  } do
    canvas(lv, "calendar:delete", %{"id" => id})

    assert has_element?(lv, "#calendar-delete-confirm", "It has 1 guest.")
    refute_enqueued(worker: CalendarEventDeleteWorker)

    lv |> element("#calendar-delete-notify") |> render_click()
    assert_enqueued(worker: CalendarEventDeleteWorker, args: %{"notify_attendees" => true})

    expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts -> :ok end)
    assert %{success: 1} = Oban.drain_queue(queue: :calendar_events, with_scheduled: true)

    assert cancelled_to() == ["ada@example.com"]

    # The email job, run through the real email service to the test mailbox.
    with_config(:tymeslot, :email_service_module, Tymeslot.Emails.EmailService)
    with_config(:swoosh, :shared_test_process, self())

    assert [email] = deliver_all("send_calendar_invitation")
    assert [{_name, "ada@example.com"}] = email.to
    assert email.subject =~ "Cancelled - Planning"
    assert email.text_body =~ "has cancelled an event you were invited to."
  end

  test "moving it says the guest has not been told", %{lv: lv, id: id} do
    stub(Tymeslot.CalendarMock, :update_event, fn _uid, _payload, _context -> :ok end)

    canvas(lv, "calendar:move", %{
      "id" => id,
      "start" => "2026-10-15T15:00",
      "end" => "2026-10-15T16:00"
    })

    assert has_element?(lv, "#calendar-toast", "Guests haven't been told.")
  end

  defp stringify(attendee), do: Map.new(attendee, fn {k, v} -> {to_string(k), v} end)
end
