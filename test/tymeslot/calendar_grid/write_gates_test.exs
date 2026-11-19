defmodule Tymeslot.CalendarGrid.WriteGatesTest do
  @moduledoc """
  The calendar's writes refuse, in the domain, what the organiser may not
  change, whoever calls them: an edit or a scheduled delete of an event on a
  read-only calendar, on someone else's integration, or held by live seats,
  and a change of timing to the calendar copy of a booking. Nothing reaches
  the provider (`Tymeslot.CalendarMock` has no expectations, so a write would
  fail the test) and no delete job is stored.
  """

  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :integration

  import Mox
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.CalendarGrid.Changes
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
