defmodule Tymeslot.Integrations.Calendar.OAuthEventErrorContractTest do
  @moduledoc """
  Locks in the error contract between the OAuth provider layer and its callers.

  Google and Outlook classify a failure as `{:error, type, message}`. Everything
  above dispatches on the atom, so the atom has to survive the trip through
  `OAuthBase.handle_api_call/2`, `ProviderAdapter` and `EventOperations`. When
  it did not, a 404 arrived at `CalendarEventSync` as `{:error, "Calendar not
  found"}`, the missing-event recovery never matched, and a booking whose
  Google event had gone kept failing its update and delete jobs for five
  attempts (issue #63).
  """

  use Tymeslot.DataCase, async: false

  @moduletag :integrations
  @moduletag :integration

  import Mox
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Integrations.Calendar.CalendarEventBuilder
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Runtime.Operations
  alias Tymeslot.Meetings.CalendarEventSync
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema

  setup :verify_on_exit!

  setup do
    user = insert(:user)

    integration =
      insert(:calendar_integration,
        user: user,
        provider: "google",
        oauth_scope: "https://www.googleapis.com/auth/calendar",
        default_booking_calendar_id: "primary"
      )

    %{user: user, integration: integration}
  end

  describe "typed provider errors through Operations" do
    test "a 404 on update surfaces as :not_found", %{user: user, integration: integration} do
      expect(GoogleCalendarAPIMock, :update_event, fn _int, "primary", "event-123", _attrs ->
        {:error, :not_found, "Event not found"}
      end)

      assert {:error, :not_found} =
               Operations.update_event(
                 "event-123",
                 %{summary: "Updated"},
                 {integration.id, user.id}
               )
    end

    test "a 404 on delete surfaces as :not_found", %{user: user, integration: integration} do
      expect(GoogleCalendarAPIMock, :delete_event, fn _int, "primary", "event-123" ->
        {:error, :not_found, "Event not found"}
      end)

      assert {:error, :not_found} =
               Operations.delete_event("event-123", {integration.id, user.id}, [])
    end

    test "an expired token surfaces as :unauthorized", %{user: user, integration: integration} do
      expect(GoogleCalendarAPIMock, :update_event, fn _int, "primary", "event-123", _attrs ->
        {:error, :unauthorized, "Token expired or invalid"}
      end)

      assert {:error, :unauthorized} =
               Operations.update_event(
                 "event-123",
                 %{summary: "Updated"},
                 {integration.id, user.id}
               )
    end
  end

  describe "booking whose provider event has gone" do
    setup %{user: user, integration: integration} do
      # CalendarEventSync normally talks to the mock; here the point is the real
      # path from the sync down to the provider, so swap in the runtime module.
      original_module = Application.get_env(:tymeslot, :calendar_module)
      Application.put_env(:tymeslot, :calendar_module, Operations)

      on_exit(fn ->
        if original_module do
          Application.put_env(:tymeslot, :calendar_module, original_module)
        else
          Application.delete_env(:tymeslot, :calendar_module)
        end
      end)

      meeting =
        insert(:meeting,
          organizer_user_id: user.id,
          calendar_integration_id: integration.id,
          calendar_path: "primary",
          provider_event_id: "google-event-gone"
        )

      %{meeting: meeting}
    end

    test "updating recreates the event Google no longer has", %{meeting: meeting} do
      expect(GoogleCalendarAPIMock, :update_event, fn _int, "primary", "google-event-gone", _a ->
        {:error, :not_found, "Event not found"}
      end)

      expect(GoogleCalendarAPIMock, :create_event, fn _int, "primary", _attrs ->
        {:ok, %{"id" => "google-event-recreated"}}
      end)

      assert :ok = CalendarEventSync.update(meeting.id, 1)

      assert Repo.get!(MeetingSchema, meeting.id).provider_event_id ==
               "google-event-recreated"
    end

    test "cancelling succeeds when the event is already gone", %{meeting: meeting} do
      {:ok, meeting} = MeetingQueries.update_meeting(meeting, %{status: :cancelled})

      expect(GoogleCalendarAPIMock, :delete_event, fn _int, "primary", "google-event-gone" ->
        {:error, :not_found, "Event not found"}
      end)

      assert :ok = CalendarEventSync.delete(meeting.id, 1)
    end
  end

  # A Google row connected before write access was required still holds a
  # read-only scope. Its client is still built from the stored integration, so
  # a write reaches Google and its 403 comes back as an error, rather than the
  # call crashing on a client that is not one.
  for {label, scope} <- [
        {"a read-only scope", "https://www.googleapis.com/auth/calendar.readonly"},
        {"no scope", nil}
      ] do
    describe "a Google integration with #{label}" do
      setup %{user: user, integration: integration} do
        integration = Repo.update!(Changeset.change(integration, oauth_scope: unquote(scope)))

        meeting =
          insert(:meeting,
            organizer_user_id: user.id,
            calendar_integration_id: integration.id,
            calendar_path: "primary"
          )

        %{integration: integration, meeting: meeting}
      end

      test "a create Google refuses for its scope comes back as an error", %{meeting: meeting} do
        expect(GoogleCalendarAPIMock, :create_event, fn %CalendarIntegrationSchema{},
                                                        "primary",
                                                        _attrs ->
          {:error, :unauthorized, "Request had insufficient authentication scopes."}
        end)

        event_data = CalendarEventBuilder.build_event_data(meeting)

        assert {:error, :unauthorized} = Operations.create_event(event_data, meeting)
      end

      test "a update Google refuses for its scope comes back as an error", %{
        user: user,
        integration: integration
      } do
        expect(GoogleCalendarAPIMock, :update_event, fn %CalendarIntegrationSchema{},
                                                        "primary",
                                                        "event-123",
                                                        _attrs ->
          {:error, :unauthorized, "Request had insufficient authentication scopes."}
        end)

        assert {:error, :unauthorized} =
                 Operations.update_event(
                   "event-123",
                   %{summary: "Updated"},
                   {integration.id, user.id}
                 )
      end

      test "a delete Google refuses for its scope comes back as an error", %{
        user: user,
        integration: integration
      } do
        expect(GoogleCalendarAPIMock, :delete_event, fn %CalendarIntegrationSchema{},
                                                        "primary",
                                                        "event-123" ->
          {:error, :unauthorized, "Request had insufficient authentication scopes."}
        end)

        assert {:error, :unauthorized} =
                 Operations.delete_event("event-123", {integration.id, user.id}, [])
      end
    end
  end
end
