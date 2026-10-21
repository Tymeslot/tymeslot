defmodule Tymeslot.CalendarGrid.EventDeletionAlreadyGoneTest do
  @moduledoc """
  Deleting a booking's calendar copy that the calendar no longer has, removed
  by another client or a sync race, still cancels the booking and tells its
  guest: the calendar answering 404 means the copy is already gone, not that
  the delete failed.

  Each provider runs its real delete path down to HTTP, so the 404 is the one
  the provider's own client classifies.
  """

  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :integration

  import Mox

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar.Google.CalendarAPI, as: GoogleCalendarAPI
  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI, as: OutlookCalendarAPI
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.Runtime.Operations
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Security.Encryption
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.EmailWorker

  setup :verify_on_exit!

  setup do
    stub_with(Tymeslot.CalendarMock, Operations)
    stub_with(GoogleCalendarAPIMock, GoogleCalendarAPI)
    stub_with(OutlookCalendarAPIMock, OutlookCalendarAPI)
    TestMocks.setup_email_mocks()

    %{user: insert(:user)}
  end

  @write_scopes %{
    "google" => "https://www.googleapis.com/auth/calendar",
    "outlook" => "Calendars.ReadWrite"
  }

  @not_found_body ~s({"error":{"code":404,"message":"Not Found"}})

  for {provider, calendar_id, event_id} <- [
        {"google", "primary", "abc123"},
        {"outlook", "AAMkCal", "AAMkEvent"},
        {"caldav", "/cal/", "/cal/booking.ics"}
      ] do
    test "a #{provider} booking copy already gone cancels the booking and tells the guest", %{
      user: user
    } do
      integration = insert_integration(user, unquote(provider))

      event =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          provider: unquote(provider),
          provider_calendar_id: unquote(calendar_id),
          provider_event_id: unquote(event_id),
          sync_state: "synced"
        )

      meeting =
        insert(:meeting,
          organizer_user_id: user.id,
          calendar_integration_id: integration.id,
          provider_event_id: unquote(event_id),
          attendee_email: "guest@example.com"
        )

      expect_not_found(unquote(provider), unquote(event_id))

      assert {:ok, %{linked_meeting: :cancelled}} = CalendarGrid.delete_event(user.id, event)

      {:ok, cancelled} = MeetingQueries.get_meeting(meeting.id)

      assert {cancelled.status, cancelled.calendar_sync_status} ==
               {"cancelled", "externally_deleted"}

      assert_enqueued(
        worker: EmailWorker,
        args: %{action: "send_cancellation_emails", meeting_id: meeting.id}
      )

      assert {:error, :not_found} =
               ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
    end
  end

  defp insert_integration(user, "caldav"),
    do: insert(:calendar_integration, user: user, provider: "caldav", calendar_paths: ["/cal/"])

  defp insert_integration(user, provider),
    do:
      insert(:calendar_integration,
        user: user,
        provider: provider,
        oauth_scope: Map.fetch!(@write_scopes, provider),
        access_token_encrypted: Encryption.encrypt("valid_token"),
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600)
      )

  defp expect_not_found("caldav", href) do
    expect(Tymeslot.HTTPClientMock, :delete, fn url, _headers, _opts ->
      assert String.ends_with?(url, href)
      {:ok, %Req.Response{status: 404, body: ""}}
    end)
  end

  defp expect_not_found(_oauth_provider, event_id) do
    expect(Tymeslot.HTTPClientMock, :request, fn :delete, url, _body, _headers, _opts ->
      assert String.contains?(url, "/events/" <> event_id)
      {:ok, %Req.Response{status: 404, body: @not_found_body}}
    end)
  end
end
