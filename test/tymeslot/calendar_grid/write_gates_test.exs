defmodule Tymeslot.CalendarGrid.WriteGatesTest do
  @moduledoc """
  The calendar's writes refuse, in the domain, what the organiser may not
  change, whoever calls them: an edit, a move, or a delete (immediate or
  scheduled) of an event on a read-only calendar, on someone else's
  integration, or held by live seats, and a change of timing or a move of
  the calendar copy of a booking. Nothing reaches the provider
  (`Tymeslot.CalendarMock` has no expectations, so a write would fail the
  test) and no delete job is stored.
  """

  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :integration

  import Mox
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.CalendarGrid.Changes
  alias Tymeslot.Integrations.Calendar.CreatedEvent
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Workers.CalendarEventDeleteWorker

  setup :verify_on_exit!

  setup do
    user = insert(:user)

    integration =
      insert(:calendar_integration,
        user: user,
        provider: "google",
        is_active: true,
        calendar_list: [
          %{"id" => "work", "name" => "Work", "selected" => true},
          %{"id" => "shared", "name" => "Shared", "selected" => true, "read_only" => true}
        ]
      )

    %{user: user, integration: integration}
  end

  defp event(integration, attrs) do
    insert(
      :provider_calendar_event,
      Map.merge(
        %{
          calendar_integration: integration,
          provider: "google",
          provider_calendar_id: "work",
          summary: "Planning",
          start_at: ~U[2026-12-01 09:00:00.000000Z],
          end_at: ~U[2026-12-01 10:00:00.000000Z],
          all_day: false,
          sync_state: "synced"
        },
        attrs
      )
    )
  end

  defp refused(reason), do: {:error, %{reason: reason, retry: :not_queued}}

  defp cached_summary(event) do
    {:ok, row} = ProviderCalendarEventQueries.get_by_uid(event.calendar_integration_id, event.uid)
    row.summary
  end

  describe "update_event/4" do
    test "refuses an event on a read-only calendar", %{user: user, integration: integration} do
      event = event(integration, %{provider_calendar_id: "shared"})

      assert Changes.update_event(user.id, event, %{summary: "Renamed"}) == refused(:read_only)
      assert cached_summary(event) == "Planning"
    end

    test "refuses an event on another user's integration", %{integration: integration} do
      event = event(integration, %{})

      assert Changes.update_event(insert(:user).id, event, %{summary: "Renamed"}) ==
               refused(:unauthorized)

      assert cached_summary(event) == "Planning"
    end

    test "refuses an event a group meeting with live seats sits on", %{
      user: user,
      integration: integration
    } do
      meeting = insert(:meeting, organizer_user: user, organizer_user_id: user.id, capacity: 2)
      insert(:participant, meeting: meeting)
      event = event(integration, %{uid: meeting.calendar_uid})

      assert Changes.update_event(user.id, event, %{summary: "Renamed"}) ==
               refused(:group_booking)
    end

    test "refuses a change of timing to a booking's calendar copy", %{
      user: user,
      integration: integration
    } do
      insert(:meeting,
        organizer_user: user,
        calendar_integration_id: integration.id,
        calendar_uid: "copy-uid"
      )

      copy = event(integration, %{uid: "copy-uid"})

      assert Changes.update_event(user.id, copy, %{
               start_at: ~U[2026-12-01 11:00:00.000000Z],
               end_at: ~U[2026-12-01 12:00:00.000000Z]
             }) == refused(:booking)
    end
  end

  describe "move_event/3" do
    setup %{user: user} do
      destination =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          is_active: true,
          calendar_list: [%{"id" => "home", "name" => "Home", "selected" => true}]
        )

      %{destination: destination}
    end

    defp move(user_id, event, destination),
      do: Changes.move_event(user_id, event, %{integration: destination, calendar_id: "home"})

    test "refuses an event on a read-only calendar", %{
      user: user,
      integration: integration,
      destination: destination
    } do
      event = event(integration, %{provider_calendar_id: "shared"})

      assert move(user.id, event, destination) == {:error, :read_only}
      assert cached_summary(event) == "Planning"
    end

    test "refuses an event on another user's integration", %{
      integration: integration,
      destination: destination
    } do
      event = event(integration, %{})

      assert move(insert(:user).id, event, destination) == {:error, :unauthorized}
      assert cached_summary(event) == "Planning"
    end

    test "refuses an event a seat was booked on since the calendar checked", %{
      user: user,
      integration: integration,
      destination: destination
    } do
      meeting = insert(:meeting, organizer_user: user, organizer_user_id: user.id, capacity: 2)
      insert(:participant, meeting: meeting)
      event = event(integration, %{uid: meeting.calendar_uid})

      assert move(user.id, event, destination) == {:error, :group_booking}
    end

    test "refuses a booking's calendar copy, which keeps the booking's time", %{
      user: user,
      integration: integration,
      destination: destination
    } do
      insert(:meeting,
        organizer_user: user,
        calendar_integration_id: integration.id,
        calendar_uid: "copy-uid"
      )

      copy = event(integration, %{uid: "copy-uid"})

      assert move(user.id, copy, destination) == {:error, :booking}
    end

    test "refuses a series member before anything is written", %{
      user: user,
      integration: integration,
      destination: destination
    } do
      event =
        event(integration, %{
          provider_calendar_id: "shared",
          recurrence_rule: "FREQ=WEEKLY",
          provider_event_id: "master-1"
        })

      assert move(user.id, event, destination) == {:error, :read_only}
    end

    test "moves an event the organiser may change", %{
      user: user,
      integration: integration,
      destination: destination
    } do
      expect(Tymeslot.CalendarMock, :create_event, fn payload, _context ->
        {:ok, CreatedEvent.new(payload.uid)}
      end)

      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts -> :ok end)

      event = event(integration, %{})

      assert {:ok, %{integration_id: id}} = move(user.id, event, destination)
      assert id == destination.id
    end
  end

  describe "delete_event/4" do
    defp gate_refused(reason), do: {:error, %{reason: reason, retry: :not_queued}}

    test "refuses an event on a read-only calendar", %{user: user, integration: integration} do
      event = event(integration, %{provider_calendar_id: "shared"})

      assert Changes.delete_event(user.id, event) == gate_refused(:read_only)
      assert cached_summary(event) == "Planning"
    end

    test "refuses an event on another user's integration", %{integration: integration} do
      event = event(integration, %{})

      assert Changes.delete_event(insert(:user).id, event) == gate_refused(:unauthorized)
      assert cached_summary(event) == "Planning"
    end

    test "refuses an event a group meeting with live seats sits on", %{
      user: user,
      integration: integration
    } do
      meeting = insert(:meeting, organizer_user: user, organizer_user_id: user.id, capacity: 2)
      insert(:participant, meeting: meeting)
      event = event(integration, %{uid: meeting.calendar_uid})

      assert Changes.delete_event(user.id, event) == gate_refused(:group_booking)
      assert cached_summary(event) == "Planning"
    end

    test "deletes an event on a calendar whose entry cannot be resolved", %{
      user: user,
      integration: integration
    } do
      expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts -> :ok end)
      event = event(integration, %{provider_calendar_id: "unlisted"})

      assert {:ok, _deleted} = Changes.delete_event(user.id, event)

      assert {:error, :not_found} =
               ProviderCalendarEventQueries.get_by_uid(integration.id, event.uid)
    end
  end

  describe "schedule_delete/4" do
    test "refuses an event on a read-only calendar", %{user: user, integration: integration} do
      event = event(integration, %{provider_calendar_id: "shared"})

      assert Changes.schedule_delete(user.id, event, :occurrence, []) == {:error, :read_only}
      refute_enqueued(worker: CalendarEventDeleteWorker)
    end

    test "refuses an event on another user's integration", %{integration: integration} do
      event = event(integration, %{})

      assert Changes.schedule_delete(insert(:user).id, event, :occurrence, []) ==
               {:error, :unauthorized}

      refute_enqueued(worker: CalendarEventDeleteWorker)
    end

    test "still deletes a booking's calendar copy, which only refuses a change of timing", %{
      user: user,
      integration: integration
    } do
      insert(:meeting,
        organizer_user: user,
        calendar_integration_id: integration.id,
        calendar_uid: "copy-uid"
      )

      copy = event(integration, %{uid: "copy-uid"})

      assert {:ok, _token} = Changes.schedule_delete(user.id, copy, :occurrence, [])
      assert_enqueued(worker: CalendarEventDeleteWorker, args: %{"uid" => "copy-uid"})
    end

    test "a delete whose calendar was disconnected during the window is not run", %{
      user: user,
      integration: integration
    } do
      Phoenix.PubSub.subscribe(Tymeslot.PubSub, "calendar_events:#{user.id}")
      event = event(integration, %{})

      {:ok, token} = Changes.schedule_delete(user.id, event, :occurrence, delay: 0)
      integration |> Changeset.change(is_active: false) |> Repo.update!()

      assert %{success: 1} = Oban.drain_queue(queue: :calendar_events, with_scheduled: true)
      assert_receive {:calendar_delete_result, _user_id, ^token, {:failed, :unauthorized}}
      assert cached_summary(event) == "Planning"
    end
  end
end
