defmodule Tymeslot.CalendarGrid.GuestUpdateTest do
  @moduledoc """
  "Tell guests" in the domain (`Changes.tell_guests/5`): the organiser of an
  event on a calendar they can write sends one update; anyone else is
  refused before anything is enqueued, for one event and for a series.
  """

  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :notifications

  import Tymeslot.Factory

  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.Changes
  alias Tymeslot.Meetings.AttendeeNotifications.Worker
  alias Tymeslot.Workers.EmailWorker

  setup do
    user = insert(:user, email: "owner@example.com")

    stored =
      insert(:calendar_integration,
        user: user,
        provider: "google",
        is_active: true,
        calendar_list: [
          %{"id" => "work", "name" => "Work", "selected" => true},
          %{"id" => "shared", "name" => "Shared", "selected" => true, "read_only" => true}
        ]
      )

    # Loaded as the calendars load them, with the calendar list cast to entries.
    [integration] = CalendarGrid.list_active_integrations(user.id)
    %{user: user, integration: integration, stored: stored}
  end

  defp review(stored, attrs \\ []) do
    insert(
      :provider_calendar_event,
      Keyword.merge(
        [
          calendar_integration: stored,
          provider: "google",
          provider_calendar_id: "work",
          summary: "Design review",
          start_at: ~U[2026-10-14 09:00:00.000000Z],
          end_at: ~U[2026-10-14 10:00:00.000000Z],
          all_day: false,
          attendees: [%{"email" => "ada@example.com"}]
        ],
        attrs
      )
    )
  end

  defp moved(event), do: %{event | location: "Room 9"}

  defp nothing_enqueued do
    assert all_enqueued(worker: Worker) == []
    assert all_enqueued(worker: EmailWorker) == []
  end

  test "the organiser's change to one event is sent as one debounced update", %{
    user: user,
    integration: integration,
    stored: stored
  } do
    event = review(stored)

    assert {:ok, :sent} =
             Changes.tell_guests(user.id, [integration], event, moved(event), :this_only)

    assert_enqueued(
      worker: Worker,
      args: %{"event_id" => event.id, "kind" => "provider_calendar_event", "action" => "update"}
    )
  end

  test "the organiser's change to a whole series is sent at once", %{
    user: user,
    integration: integration,
    stored: stored
  } do
    event = review(stored)

    assert {:ok, :sent} = Changes.tell_guests(user.id, [integration], event, moved(event), :all)

    assert [%{args: %{"attendee_emails" => ["ada@example.com"], "series" => "all"}}] =
             all_enqueued(worker: EmailWorker)
  end

  test "nothing guests would see has changed: nothing is sent", %{
    user: user,
    integration: integration,
    stored: stored
  } do
    event = review(stored)

    assert {:ok, :noop} = Changes.tell_guests(user.id, [integration], event, event, nil)
    nothing_enqueued()
  end

  describe "an event someone else organises" do
    setup %{stored: stored} do
      %{event: review(stored, organiser: %{"email" => "boss@elsewhere.example"})}
    end

    test "is refused and tells nobody", %{user: user, integration: integration, event: event} do
      assert {:error, :not_organiser} =
               Changes.tell_guests(user.id, [integration], event, moved(event), :this_only)

      nothing_enqueued()
    end

    test "is refused for a series scope too", %{
      user: user,
      integration: integration,
      event: event
    } do
      assert {:error, :not_organiser} =
               Changes.tell_guests(user.id, [integration], event, moved(event), :following)

      nothing_enqueued()
    end
  end

  test "an event on a read-only calendar is refused and tells nobody", %{
    user: user,
    integration: integration,
    stored: stored
  } do
    event = review(stored, provider_calendar_id: "shared")

    assert {:error, :read_only} =
             Changes.tell_guests(user.id, [integration], event, moved(event), :all)

    nothing_enqueued()
  end

  test "an event on another user's integration is refused and tells nobody", %{
    user: user,
    integration: integration
  } do
    other = insert(:calendar_integration, provider: "google")
    event = review(other)

    assert {:error, :unauthorized} =
             Changes.tell_guests(user.id, [integration], event, moved(event), nil)

    nothing_enqueued()
  end
end
