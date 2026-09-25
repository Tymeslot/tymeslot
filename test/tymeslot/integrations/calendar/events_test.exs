defmodule Tymeslot.Integrations.Calendar.EventsTest do
  @moduledoc """
  The write-side surface of `Calendar.Events` that the calendar grid relies
  on: deletes dispatch through the configured `:calendar_module` seam (so
  tests can drive them), a delete reconciles the meeting it removes, and
  failed writes are queued for retry only when a retry can succeed.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :integrations

  import Mox

  alias Tymeslot.Integrations.Calendar.Events
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  describe "delete_event/3" do
    test "dispatches uid, context and opts through the calendar module" do
      expect(Tymeslot.CalendarMock, :delete_event, fn uid, context, opts ->
        send(self(), {:deleted, uid, context, opts})
        {:error, {:echo, opts[:provider_event_id]}}
      end)

      assert {:error, {:echo, "prov-1"}} =
               Events.delete_event("uid-1", {7, 9}, provider_event_id: "prov-1")

      assert_received {:deleted, "uid-1", {7, 9}, [provider_event_id: "prov-1"]}
    end

    test "defaults to no context and no opts" do
      expect(Tymeslot.CalendarMock, :delete_event, fn uid, context, opts ->
        send(self(), {:deleted, uid, context, opts})
        :ok
      end)

      assert :ok = Events.delete_event("uid-2")
      assert_received {:deleted, "uid-2", nil, []}
    end
  end

  describe "delete_event_and_reconcile/4" do
    setup do
      TestMocks.setup_email_mocks()
      %{integration: insert(:calendar_integration)}
    end

    test "cancels the linked meeting and reports its attendee", %{integration: integration} do
      user_id = integration.user_id

      meeting =
        insert(:meeting,
          calendar_integration_id: integration.id,
          provider_event_id: "prov-linked",
          attendee_email: "guest@example.com"
        )

      expect(Tymeslot.CalendarMock, :delete_event, fn "uid-linked",
                                                      {_integration_id, ^user_id},
                                                      [provider_event_id: "prov-linked"] ->
        :ok
      end)

      assert {:ok, result} =
               Events.delete_event_and_reconcile(
                 "uid-linked",
                 "prov-linked",
                 {integration.id, user_id},
                 provider_event_id: "prov-linked"
               )

      assert result == %{
               uid: "uid-linked",
               integration_id: integration.id,
               reconcile_result: :ok,
               meeting_attendee_email: "guest@example.com"
             }

      {:ok, updated} = MeetingQueries.get_meeting(meeting.id)
      assert updated.status == "cancelled"
      assert updated.calendar_sync_status == "externally_deleted"
    end

    test "omits the attendee when no meeting is linked", %{integration: integration} do
      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts -> :ok end)

      assert {:ok, result} =
               Events.delete_event_and_reconcile(
                 "uid-free",
                 nil,
                 {integration.id, integration.user_id},
                 []
               )

      assert result == %{uid: "uid-free", integration_id: integration.id, reconcile_result: :ok}
    end

    test "leaves the linked meeting alone when the delete fails", %{integration: integration} do
      meeting =
        insert(:meeting,
          calendar_integration_id: integration.id,
          provider_event_id: "prov-kept"
        )

      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts ->
        {:error, :unauthorized}
      end)

      assert {:error, :unauthorized} =
               Events.delete_event_and_reconcile(
                 "uid-kept",
                 "prov-kept",
                 {integration.id, integration.user_id},
                 []
               )

      {:ok, unchanged} = MeetingQueries.get_meeting(meeting.id)
      assert unchanged.status == meeting.status
      assert unchanged.calendar_sync_status == nil
    end
  end

  describe "event_linked_to_booking?/3" do
    setup do
      integration = insert(:calendar_integration)

      insert(:meeting,
        calendar_integration_id: integration.id,
        uid: "meeting-uid",
        provider_event_id: nil
      )

      %{integration: integration}
    end

    test "matches a meeting by uid", %{integration: integration} do
      assert Events.event_linked_to_booking?(integration.id, "some-href", "meeting-uid")
    end

    test "is false for an event no meeting mirrors", %{integration: integration} do
      refute Events.event_linked_to_booking?(integration.id, "some-href", "foreign-uid")
    end
  end

  describe "queue_for_offline_retry/3" do
    test "queues the write on a CalDAV integration" do
      integration = insert(:calendar_integration, provider: "caldav", calendar_paths: ["/cal/"])
      target = %{uid: "queued-uid", calendar_integration_id: integration.id}

      assert :ok =
               Events.queue_for_offline_retry(target, :update, %{
                 summary: "Retry me",
                 start_time: ~U[2026-05-01 10:00:00Z],
                 end_time: ~U[2026-05-01 11:00:00Z]
               })

      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, "queued-uid")
      assert row.sync_state == "locally_modified"
      assert row.summary == "Retry me"
    end

    test "is ignored on a provider without an offline queue" do
      integration = insert(:calendar_integration, provider: "google", calendar_paths: [])
      target = %{uid: "google-uid", calendar_integration_id: integration.id}

      assert :ignored = Events.queue_for_offline_retry(target, :delete, %{})

      assert {:error, :not_found} =
               ProviderCalendarEventQueries.get_by_uid(integration.id, "google-uid")
    end
  end

  describe "queueable_error?/1" do
    for {reason, expected} <- [
          unauthorized: false,
          not_found: false,
          meeting_not_found: false,
          rate_limited: false,
          timeout: true,
          network_error: true,
          server_error: true
        ] do
      test "#{inspect(reason)} is #{if expected, do: "", else: "not "}queueable" do
        assert Events.queueable_error?(unquote(reason)) == unquote(expected)
      end
    end

    test "a non-atom reason is queueable" do
      assert Events.queueable_error?({:http_error, 502})
    end
  end
end
