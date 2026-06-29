defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.EventCreateTest do
  @moduledoc """
  Tests for EventCreate — the presentation layer of the dashboard calendar-grid
  create flow. `handle_create_result/2` translates the domain orchestration's
  result map into cache writes, grid updates, and user-facing flashes:

    * persists `video_integration_id` and description to the cache row, and
      flashes copy that reflects attendee presence,
    * flashes the "no Meet link" warning when the domain signals one, and
    * flashes the "reconnect your calendar" error when the domain returns
      `reauth_required: true`.

  The orchestration itself (`run_create_event/1`) is covered in
  `Tymeslot.CalendarGrid.EventCreationTest`.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :integration

  import Tymeslot.Factory

  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.EventCreation
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.CreateExecution
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.CreateFormState

  describe "handle_create_result/2" do
    test "flashes 'Event created.' when there are no attendees" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true)

      result = build_result(integration, attendees: [])
      socket = build_socket()

      {:noreply, updated_socket} = CreateExecution.handle_create_result({:ok, result}, socket)

      assert updated_socket.assigns.flash["info"] == "Event created."
    end

    test "flashes 'Event created. Attendees have been invited.' with attendees" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true)

      result = build_result(integration, attendees: [%{email: "a@x.com"}])
      socket = build_socket()

      {:noreply, updated_socket} = CreateExecution.handle_create_result({:ok, result}, socket)

      assert updated_socket.assigns.flash["info"] ==
               "Event created. Attendees have been invited."
    end

    test "persists reminders on the cached event" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true)

      result =
        build_result(integration,
          attendees: [],
          reminders: [%{method: :popup, minutes_before: 10}]
        )

      socket = build_socket()

      {:noreply, _socket} = CreateExecution.handle_create_result({:ok, result}, socket)

      {:ok, cached} = CalendarGrid.get_cached_event(integration.id, result.uid)
      assert cached.reminders == [%{method: :popup, minutes_before: 10}]
    end

    test "persists the recurrence rule on the cached event" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true)

      result =
        build_result(integration,
          attendees: [],
          recurrence_rule: "FREQ=WEEKLY;BYDAY=MO,WE"
        )

      socket = build_socket()

      {:noreply, _socket} = CreateExecution.handle_create_result({:ok, result}, socket)

      {:ok, cached} = CalendarGrid.get_cached_event(integration.id, result.uid)
      assert cached.recurrence_rule == "FREQ=WEEKLY;BYDAY=MO,WE"
    end

    test "persists video_integration_id and description on the cached event" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true)
      video_integration = insert(:video_integration, user: user)

      result =
        build_result(integration,
          attendees: [%{email: "a@x.com"}],
          video_integration_id: video_integration.id,
          description: "Weekly sync\n\nJoin video call: https://meet.example.com/abc"
        )

      socket = build_socket()

      {:noreply, _socket} = CreateExecution.handle_create_result({:ok, result}, socket)

      {:ok, cached} = CalendarGrid.get_cached_event(integration.id, result.uid)
      assert cached.description =~ "https://meet.example.com/abc"
      assert cached.description =~ "Weekly sync"
    end
  end

  describe "handle_create_result/2 — no Meet URL warning" do
    test "flashes a warning alongside the success info when :warning key is present" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true)

      result =
        build_result(integration,
          attendees: [],
          warning:
            "Google Calendar saved the event but didn't return a Meet link — please try again or add it manually."
        )

      socket = build_socket()

      {:noreply, updated_socket} = CreateExecution.handle_create_result({:ok, result}, socket)

      assert updated_socket.assigns.flash["info"] == "Event created."
      assert updated_socket.assigns.flash["warning"] =~ "Meet link"
    end

    test "does not flash a warning when :warning key is absent" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true)

      result = build_result(integration, attendees: [])
      socket = build_socket()

      {:noreply, updated_socket} = CreateExecution.handle_create_result({:ok, result}, socket)

      assert updated_socket.assigns.flash["info"] == "Event created."
      assert is_nil(updated_socket.assigns.flash["warning"])
    end
  end

  describe "handle_create_result/2 — reauth required" do
    test "flashes the reconnect error when the domain returns reauth_required: true" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true)

      result = build_result(integration, attendees: [], reauth_required: true)
      socket = build_socket()

      {:noreply, updated_socket} = CreateExecution.handle_create_result({:ok, result}, socket)

      # The event still saved, so the success info flash is present…
      assert updated_socket.assigns.flash["info"] == "Event created."
      # …and the reconnect prompt now reaches the user from the LiveView layer.
      assert updated_socket.assigns.flash["error"] == EventCreation.reauth_flash_message()
    end

    test "does not flash a reconnect error when reauth_required is false" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, is_active: true)

      result = build_result(integration, attendees: [], reauth_required: false)
      socket = build_socket()

      {:noreply, updated_socket} = CreateExecution.handle_create_result({:ok, result}, socket)

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

  defp build_result(integration, opts) do
    attendees = Keyword.get(opts, :attendees, [])
    video_integration_id = Keyword.get(opts, :video_integration_id, nil)
    description = Keyword.get(opts, :description, nil)
    warning = Keyword.get(opts, :warning, nil)
    reauth_required = Keyword.get(opts, :reauth_required, false)
    reminders = Keyword.get(opts, :reminders, [])
    recurrence_rule = Keyword.get(opts, :recurrence_rule, nil)

    base = %{
      uid: "uid-" <> Integer.to_string(System.unique_integer([:positive])),
      creating: %{
        title: "New Event",
        integration_id: integration.id,
        calendar_id: "primary",
        reminders: reminders,
        recurrence_rule: recurrence_rule,
        video_integration_id: video_integration_id
      },
      start_at: ~U[2026-04-06 09:00:00Z],
      end_at: ~U[2026-04-06 09:30:00Z],
      provider: integration.provider,
      default_booking_calendar_id: nil,
      reauth_required: reauth_required,
      attendees: attendees,
      meeting_url: nil,
      video_room_id: nil,
      description: description
    }

    if warning, do: Map.put(base, :warning, warning), else: base
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
