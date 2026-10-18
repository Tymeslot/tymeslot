defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.EventCreateTest do
  @moduledoc """
  The old calendar's create result handler: `handle_create_result/2` turns
  what `Changes.create_event/2` answered into the grid's reload and the
  flashes (the invited guests, the "no Meet link" warning, the "reconnect
  your calendar" error). The caching itself is the domain's, covered in
  `Tymeslot.CalendarGrid.ChangesCreateTest`.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :integration

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.Changes
  alias Tymeslot.CalendarGrid.EventCreation
  alias Tymeslot.Integrations.Calendar.CreatedEvent
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.CreateExecution
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.CreateFormState

  setup :verify_on_exit!

  describe "handle_create_result/2" do
    test "flashes 'Event created.' when nobody was invited" do
      {:noreply, socket} =
        CreateExecution.handle_create_result({:ok, created(invited: [])}, build_socket())

      assert socket.assigns.flash["info"] == "Event created."
    end

    test "flashes 'Event created. Attendees have been invited.' when guests were" do
      {:noreply, socket} =
        CreateExecution.handle_create_result(
          {:ok, created(invited: ["a@x.com"])},
          build_socket()
        )

      assert socket.assigns.flash["info"] == "Event created. Attendees have been invited."
    end
  end

  describe "drawing an event on the grid, end to end" do
    # The whole point of the create answering with the event's identity is that
    # it reaches the cache row the grid reads back.
    test "files the provider's ETag on the row the grid reads back" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, provider: "caldav", is_active: true)

      expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
        {:ok,
         CreatedEvent.new(event_data.uid,
           provider_event_id: "/calendars/user/personal/#{event_data.uid}.ics",
           etag: "server-assigned-1"
         )}
      end)

      payload = %{
        creating: %{
          title: "Focus time",
          integration_id: integration.id,
          calendar_id: "primary",
          attendees: []
        },
        user_id: user.id,
        start_at: ~U[2026-04-06 09:00:00Z],
        end_at: ~U[2026-04-06 09:30:00Z]
      }

      assert {:ok, %{event: event} = created} = Changes.create_event(user.id, payload)
      {:noreply, _socket} = CreateExecution.handle_create_result({:ok, created}, build_socket())

      {:ok, cached} = CalendarGrid.get_cached_event(integration.id, event.uid)
      assert cached.etag == "server-assigned-1"
      assert cached.provider_event_id == "/calendars/user/personal/#{event.uid}.ics"
      # The server's own copy of the document is not echoed back from what we
      # submitted, so it is still the first sync's job to supply it.
      assert is_nil(cached.raw_ical)
    end

    test "a repeat rule Outlook refuses fails the create, and the flash says why" do
      user = insert(:user)

      integration =
        insert(:calendar_integration, user: user, provider: "outlook", is_active: true)

      # Refused before anything is written, so no video room is made either.
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

      assert {:error, %{reason: :rule_not_supported_by_outlook, retry: :not_queued} = failure} =
               Changes.create_event(user.id, payload)

      {:noreply, socket} = CreateExecution.handle_create_result({:error, failure}, build_socket())

      assert socket.assigns.flash["error"] == "This repeat pattern can't be saved to Outlook."
    end
  end

  describe "handle_create_result/2 — no Meet URL warning" do
    test "flashes a warning alongside the success info when :warning key is present" do
      {:noreply, updated_socket} =
        CreateExecution.handle_create_result(
          {:ok,
           created(
             warning:
               "Google Calendar saved the event but didn't return a Meet link — please try again or add it manually."
           )},
          build_socket()
        )

      assert updated_socket.assigns.flash["info"] == "Event created."
      assert updated_socket.assigns.flash["warning"] =~ "Meet link"
    end

    test "does not flash a warning when :warning key is absent" do
      {:noreply, updated_socket} =
        CreateExecution.handle_create_result({:ok, created()}, build_socket())

      assert updated_socket.assigns.flash["info"] == "Event created."
      assert is_nil(updated_socket.assigns.flash["warning"])
    end
  end

  describe "handle_create_result/2 — reauth required" do
    test "flashes the reconnect error when the domain returns reauth_required: true" do
      {:noreply, updated_socket} =
        CreateExecution.handle_create_result(
          {:ok, created(reauth_required: true)},
          build_socket()
        )

      # The event still saved, so the success info flash is present…
      assert updated_socket.assigns.flash["info"] == "Event created."
      # …and the reconnect prompt now reaches the user from the LiveView layer.
      assert updated_socket.assigns.flash["error"] == EventCreation.reauth_flash_message()
    end

    test "does not flash a reconnect error when reauth_required is false" do
      {:noreply, updated_socket} =
        CreateExecution.handle_create_result(
          {:ok, created(reauth_required: false)},
          build_socket()
        )

      assert is_nil(updated_socket.assigns.flash["error"])
    end
  end

  describe "handle_save_event/2 — authorization (T-69)" do
    test "rejects a create targeting an integration the user does not own" do
      user = insert(:user)
      # owned_integration_ids is empty, so any integration id is unauthorised.
      socket = build_create_socket(user, 999, [])

      {:noreply, returned_socket} = CreateExecution.handle_save_event(%{}, socket)

      assert_receive {:flash, {:error, "Invalid calendar selected"}}
      # The save must not have been dispatched to the domain layer.
      refute_receive {:execute_create_event, _payload}
      assert returned_socket.assigns.saving_event == false
    end

    test "dispatches the create when the user owns the target integration" do
      user = insert(:user)
      socket = build_create_socket(user, 42, [42])

      {:noreply, returned_socket} = CreateExecution.handle_save_event(%{}, socket)

      assert_receive {:execute_create_event, payload}
      assert payload.creating.integration_id == 42
      assert payload.user_id == user.id
      assert returned_socket.assigns.saving_event == true
      refute_receive {:flash, {:error, "Invalid calendar selected"}}
    end
  end

  describe "handle_update_create_integration/2" do
    test "is a no-op when the create form has already been closed (creating_event is nil)" do
      # A duplicate/queued integration-change event can arrive after the create
      # form closed and cleared creating_event. It must not crash on Map.put(nil).
      socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, creating_event: nil}}

      assert {:noreply, ^socket} =
               CreateFormState.handle_update_create_integration(
                 %{"integration-id" => "1", "calendar-id" => "primary"},
                 socket
               )
    end
  end

  # Helpers

  defp created(opts \\ []) do
    %{
      event: nil,
      invited: Keyword.get(opts, :invited, []),
      warning: Keyword.get(opts, :warning),
      reauth_required: Keyword.get(opts, :reauth_required, false)
    }
  end

  defp build_socket do
    %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, flash: %{}}
    }
  end

  # Socket for the save handler: a timed event being created on `integration_id`,
  # with `owned_ids` standing in for the user's active integrations (the same
  # MapSet that gates move/resize/delete).
  defp build_create_socket(user, integration_id, owned_ids) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        current_user: user,
        user_timezone: "Europe/Berlin",
        saving_event: false,
        owned_integration_ids: MapSet.new(owned_ids),
        creating_event: %{
          title: "Blocked Time",
          integration_id: integration_id,
          calendar_id: "primary",
          date: "2026-04-06",
          end_date: "2026-04-06",
          start_hour: 9,
          start_minute: 0,
          end_hour: 10,
          end_minute: 0,
          all_day: false,
          attendees: [],
          reminders: [],
          recurrence_rule: nil,
          video_integration_id: nil
        }
      }
    }
  end
end
