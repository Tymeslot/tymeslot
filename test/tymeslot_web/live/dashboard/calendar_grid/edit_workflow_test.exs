defmodule TymeslotWeb.Dashboard.CalendarGrid.EditWorkflowTest do
  @moduledoc """
  Tests for the Task 15 refactor: `notify_event_updated/3` routes edit-flow
  notifications through `Tymeslot.Meetings.AttendeeNotifications`, and
  `sync_video_integration_async/3` provisions a video room asynchronously
  and persists the resulting `video_link` onto the event row when the video
  selector changes.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :integration

  import Tymeslot.Factory

  alias Phoenix.Component
  alias Tymeslot.Meetings.AttendeeNotifications
  alias Tymeslot.Meetings.AttendeeNotifications.ChangeSummary
  alias Tymeslot.Meetings.AttendeeNotifications.Worker
  alias TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow
  alias TymeslotWeb.Dashboard.CalendarGrid.EditWorkflowTest.FakeRooms

  describe "notify_event_updated/3" do
    test "returns {:needs_confirmation, summary} for a title edit on an event with attendees" do
      event = build_event(attendees: [%{"email" => "a@x.com"}])
      updated = %{event | summary: "New Title"}

      assert {:needs_confirmation, %ChangeSummary{} = summary} =
               EditWorkflow.notify_event_updated(event, updated, event.attendees)

      assert ChangeSummary.any_changes?(summary)
      refute_enqueued(worker: Worker)
    end

    test "after confirm, a Worker job is enqueued with the correct args" do
      event = build_event(attendees: [%{"email" => "a@x.com"}])
      updated = %{event | summary: "New Title"}

      {:needs_confirmation, summary} =
        EditWorkflow.notify_event_updated(event, updated, event.attendees)

      {:ok, :sent} =
        AttendeeNotifications.event_updated_confirm(
          updated,
          summary,
          event.attendees
        )

      assert_enqueued(
        worker: Worker,
        args: %{
          "event_id" => event.id,
          "kind" => "provider_calendar_event",
          "action" => "update"
        }
      )
    end

    test "a second edit while a Worker job is pending returns {:ok, :already_pending} and does not re-prompt" do
      event = build_event(attendees: [%{"email" => "a@x.com"}])
      first_update = %{event | summary: "First"}
      second_update = %{event | summary: "Second"}

      {:needs_confirmation, summary} =
        EditWorkflow.notify_event_updated(event, first_update, event.attendees)

      {:ok, :sent} =
        AttendeeNotifications.event_updated_confirm(
          first_update,
          summary,
          event.attendees
        )

      # The second edit should collapse into the existing debounced job.
      assert {:ok, :already_pending} =
               EditWorkflow.notify_event_updated(event, second_update, event.attendees)

      # Still exactly one queued job for this event/action — the second call
      # replaced scheduled_at rather than enqueuing a new job.
      jobs = all_enqueued(worker: Worker)

      assert Enum.count(jobs, fn job ->
               job.args["event_id"] == event.id and job.args["action"] == "update"
             end) == 1
    end

    test "returns {:ok, :no_changes} when the event has no attendees" do
      event = build_event(attendees: [])
      updated = %{event | summary: "New Title"}

      assert {:ok, :no_changes} =
               EditWorkflow.notify_event_updated(event, updated, [])

      refute_enqueued(worker: Worker)
    end

    test "returns {:ok, :no_changes} when only a non-notifiable field changed" do
      event = build_event(attendees: [%{"email" => "a@x.com"}])
      # The cached row carries many fields that are irrelevant to attendees
      # (e.g. synced_at). Round-tripping the event through itself must not
      # trip the diff.
      updated = %{event | synced_at: DateTime.utc_now(:second)}

      assert {:ok, :no_changes} =
               EditWorkflow.notify_event_updated(event, updated, event.attendees)

      refute_enqueued(worker: Worker)
    end
  end

  describe "sync_video_integration_async/3" do
    setup do
      original = Application.get_env(:tymeslot, :video_rooms_module)
      on_exit(fn -> restore_env(:video_rooms_module, original) end)

      user = insert(:user)

      socket = Component.assign(%Phoenix.LiveView.Socket{}, :current_user, user)

      {:ok, socket: socket, user: user}
    end

    test "provisions a room and sends result when video_integration_id becomes set",
         %{socket: socket} do
      event = build_event(attendees: [])
      integration_id = 42

      Application.put_env(:tymeslot, :video_rooms_module, FakeRooms)

      FakeRooms.set_response(
        {:ok,
         %{
           room_data: %{
             meeting_url: "https://video.example.com/join/abc",
             room_id: "abc"
           }
         }}
      )

      updated_event = %{event | video_integration_id: integration_id}

      _socket = EditWorkflow.sync_video_integration_async(socket, event, updated_event)

      assert_receive {:video_sync_result, event_id, {:ok, "https://video.example.com/join/abc"}}
      assert event_id == event.id
    end

    test "returns socket unchanged when the integration id did not change",
         %{socket: socket} do
      video_integration = insert(:video_integration)
      event = build_event(video_integration_id: video_integration.id)

      Application.put_env(:tymeslot, :video_rooms_module, FakeRooms)
      FakeRooms.set_response({:error, :should_not_be_called})

      returned_socket = EditWorkflow.sync_video_integration_async(socket, event, event)

      assert returned_socket == socket
      refute_receive {:video_sync_result, _, _}
    end

    test "clears video_link when the integration id is removed", %{socket: socket} do
      video_integration = insert(:video_integration)

      event =
        build_event(
          video_integration_id: video_integration.id,
          video_link: "https://old.example.com/join"
        )

      updated = %{event | video_integration_id: nil}

      Application.put_env(:tymeslot, :video_rooms_module, FakeRooms)
      FakeRooms.set_response({:error, :should_not_be_called})

      _socket = EditWorkflow.sync_video_integration_async(socket, event, updated)

      assert_receive {:video_sync_result, event_id, {:ok, nil}}
      assert event_id == event.id
    end

    test "sends error result and does not persist when provisioning fails", %{socket: socket} do
      video_integration = insert(:video_integration)
      event = build_event(video_integration_id: nil, video_link: nil)
      updated = %{event | video_integration_id: video_integration.id}

      Application.put_env(:tymeslot, :video_rooms_module, FakeRooms)
      FakeRooms.set_response({:error, :provider_down})

      _socket = EditWorkflow.sync_video_integration_async(socket, event, updated)

      assert_receive {:video_sync_result, event_id, {:error, :provider_down}}
      assert event_id == event.id
    end
  end

  # Helpers

  defp build_event(opts) do
    insert(
      :provider_calendar_event,
      Keyword.merge(
        [
          summary: "Team Sync",
          location: "",
          description: "",
          attendees: [],
          start_at: ~U[2026-05-01 09:00:00.000000Z],
          end_at: ~U[2026-05-01 10:00:00.000000Z],
          synced_at: ~U[2026-05-01 09:00:00.000000Z],
          all_day: false
        ],
        opts
      )
    )
  end

  defp restore_env(key, nil), do: Application.delete_env(:tymeslot, key)
  defp restore_env(key, value), do: Application.put_env(:tymeslot, key, value)
end

# Minimal stub module used as a drop-in replacement for
# `Tymeslot.Integrations.Video.Rooms` inside the EditWorkflow test. Only
# `create_meeting_room/2` is reached by the code under test.
defmodule TymeslotWeb.Dashboard.CalendarGrid.EditWorkflowTest.FakeRooms do
  @moduledoc false

  @spec start() :: :ok | :ets.table()
  def start do
    case :ets.whereis(__MODULE__) do
      :undefined -> :ets.new(__MODULE__, [:set, :public, :named_table])
      _ref -> :ok
    end
  end

  @spec set_response(term()) :: :ok
  def set_response(resp) do
    start()
    :ets.insert(__MODULE__, {:response, resp})
    :ok
  end

  @spec create_meeting_room(integer() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def create_meeting_room(_user_id, _opts) do
    start()

    case :ets.lookup(__MODULE__, :response) do
      [{:response, resp}] -> resp
      [] -> {:error, :no_response_configured}
    end
  end
end
