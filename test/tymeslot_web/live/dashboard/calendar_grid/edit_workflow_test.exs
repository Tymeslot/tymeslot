defmodule TymeslotWeb.Dashboard.CalendarGrid.EditWorkflowTest do
  @moduledoc """
  Tests for the edit workflow helpers: `notify_event_updated/3` routes
  edit-flow notifications through `Tymeslot.Meetings.AttendeeNotifications`,
  and the ownership and writability guards every grid write goes through.
  Changing an event's video room is covered in
  `Tymeslot.CalendarGrid.EventVideoTest`.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :integration

  import Mox
  import Tymeslot.Factory

  alias Phoenix.Component
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Meetings.AttendeeNotifications
  alias Tymeslot.Meetings.AttendeeNotifications.ChangeSummary
  alias Tymeslot.Meetings.AttendeeNotifications.Worker
  alias TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow

  describe "default_calendar_id_for/1" do
    test "resolves to a calendar the picker actually renders, not an unselected primary" do
      # A is the provider-primary but has been unselected (e.g. via "Manage
      # calendars"); B is selected and not read-only. The picker only offers
      # chips for `Calendar.writable_calendars/1` (selected, not read-only),
      # so the resolved default must agree with that same subset or the
      # write path and the highlighted chip diverge.
      integration = %{
        default_booking_calendar_id: nil,
        calendar_list: [
          %CalendarEntry{id: "cal-a", primary: true, selected: false, read_only: false},
          %CalendarEntry{id: "cal-b", primary: false, selected: true, read_only: false}
        ]
      }

      resolved_id = EditWorkflow.default_calendar_id_for(integration)

      assert resolved_id == "cal-b"

      rendered_ids = Enum.map(Calendar.writable_calendars(integration.calendar_list), & &1.id)
      assert resolved_id in rendered_ids
    end
  end

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

  describe "assert_owns_event/2 and assert_owns_integration/2" do
    test "returns :ok when the event's integration is owned" do
      socket = socket_owning([7, 9])
      event = %{calendar_integration_id: 7}

      assert EditWorkflow.assert_owns_event(socket, event) == :ok
    end

    test "returns {:error, :unauthorized} when the event's integration is not owned" do
      socket = socket_owning([7, 9])
      event = %{calendar_integration_id: 13}

      assert EditWorkflow.assert_owns_event(socket, event) == {:error, :unauthorized}
    end

    test "assert_owns_integration/2 authorises an owned integration id" do
      socket = socket_owning([7, 9])

      assert EditWorkflow.assert_owns_integration(socket, 9) == :ok
    end

    test "assert_owns_integration/2 rejects an unowned integration id" do
      socket = socket_owning([7, 9])

      assert EditWorkflow.assert_owns_integration(socket, 13) == {:error, :unauthorized}
    end

    test "assert_owns_integration/2 rejects a nil integration id" do
      socket = socket_owning([7, 9])

      assert EditWorkflow.assert_owns_integration(socket, nil) == {:error, :unauthorized}
    end
  end

  describe "assert_event_writable/2 and event_editable?/2" do
    test "allows an event on a writable calendar" do
      socket = socket_with_integration(google_integration())
      event = event_on("own@example.com")

      assert EditWorkflow.assert_event_writable(socket, event) == :ok
      assert EditWorkflow.event_editable?(socket.assigns, event)
    end

    test "refuses an event on a read-only calendar of a writable provider" do
      socket = socket_with_integration(google_integration())
      event = event_on("shared@example.com")

      assert EditWorkflow.assert_event_writable(socket, event) == {:error, :read_only}
      refute EditWorkflow.event_editable?(socket.assigns, event)
    end

    test "refuses every event on a read-only provider" do
      integration = %{
        id: 7,
        provider: "ics_url",
        calendar_list: [%CalendarEntry{id: "feed", selected: true, read_only: true}]
      }

      socket = socket_with_integration(integration)
      event = event_on("feed")

      assert EditWorkflow.assert_event_writable(socket, event) == {:error, :read_only}
      refute EditWorkflow.event_editable?(socket.assigns, event)
    end

    test "reports an unowned event as unauthorized rather than read-only" do
      socket = socket_with_integration(google_integration())
      event = %{event_on("own@example.com") | calendar_integration_id: 13}

      assert EditWorkflow.assert_event_writable(socket, event) == {:error, :unauthorized}
      refute EditWorkflow.event_editable?(socket.assigns, event)
    end
  end

  # Helpers

  defp google_integration do
    %{
      id: 7,
      provider: "google",
      calendar_list: [
        %CalendarEntry{id: "own@example.com", selected: true, read_only: false},
        %CalendarEntry{id: "shared@example.com", selected: true, read_only: true}
      ]
    }
  end

  defp event_on(provider_calendar_id) do
    %{
      calendar_integration_id: 7,
      provider_calendar_id: provider_calendar_id,
      provider_event_id: "evt-1"
    }
  end

  defp socket_with_integration(integration) do
    [integration.id]
    |> socket_owning()
    |> Component.assign(:integrations, [integration])
  end

  defp socket_owning(integration_ids) do
    Component.assign(
      %Phoenix.LiveView.Socket{},
      :owned_integration_ids,
      MapSet.new(integration_ids)
    )
  end

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
end
