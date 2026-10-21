defmodule Tymeslot.CalendarGrid.EventEditQueueForRetryTest do
  @moduledoc """
  A grid edit that could not reach a CalDAV server is queued for the next
  sync, unless it leaves the event part of a series. The queue never
  replays a series member's change, so a one-off given a rule would sit
  there unsent while the grid called it saved; it is refused instead, on
  the direct write and on the hand-over of the grid's write queue
  (`Tymeslot.CalendarGrid.WriteHandOver`).
  """

  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :integration

  import Mox

  alias Ecto.Changeset
  alias Tymeslot.CalendarGrid.EventEdit
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Integrations.Calendar.Runtime.Operations

  setup :verify_on_exit!

  setup do
    previous_module = Application.get_env(:tymeslot, :calendar_module)
    Application.put_env(:tymeslot, :calendar_module, Operations)

    on_exit(fn ->
      if previous_module,
        do: Application.put_env(:tymeslot, :calendar_module, previous_module),
        else: Application.delete_env(:tymeslot, :calendar_module)
    end)

    user = insert(:user)

    integration =
      insert(:calendar_integration,
        user: user,
        provider: "caldav",
        base_url: "https://caldav.example.com",
        calendar_paths: ["/cal/"]
      )

    row =
      insert(:provider_calendar_event,
        calendar_integration: integration,
        uid: "planning",
        provider: "caldav",
        provider_calendar_id: "/cal/",
        provider_event_id: "/cal/planning.ics",
        summary: "Planning",
        start_at: ~U[2026-10-05 07:00:00.000000Z],
        end_at: ~U[2026-10-05 08:00:00.000000Z],
        all_day: false,
        timezone: "Etc/UTC",
        sync_state: "synced"
      )

    %{user: user, row: row, event: ProviderCalendarEventSchema.to_calendar_event(row)}
  end

  defp assert_untouched(row) do
    stored = Repo.reload!(row)
    assert stored.sync_state == "synced"
    assert stored.recurrence_rule == nil
  end

  defp server_unavailable do
    stub(Tymeslot.HTTPClientMock, :put, fn _url, _body, _headers, _opts ->
      {:ok, %Req.Response{status: 503, body: "", headers: %{}}}
    end)
  end

  describe "a one-off given a rule" do
    test "is not queued when the server cannot be reached", %{
      user: user,
      row: row,
      event: event
    } do
      server_unavailable()

      assert {:error, %{retry: :not_queued}} =
               EventEdit.update_event(user.id, event, %{recurrence_rule: "FREQ=WEEKLY"},
                 timezone: "Europe/Berlin"
               )

      assert_untouched(row)
    end

    test "is not queued from the grid's write queue", %{user: user, row: row, event: event} do
      assert {:error, :not_queued} =
               EventEdit.queue_for_retry(user.id, event, %{recurrence_rule: "FREQ=WEEKLY"},
                 timezone: "Europe/Berlin"
               )

      assert_untouched(row)
    end
  end

  describe "an edit that leaves a one-off a one-off" do
    test "is queued when the server cannot be reached", %{user: user, row: row, event: event} do
      server_unavailable()

      assert {:error, %{retry: :queued}} =
               EventEdit.update_event(user.id, event, %{summary: "Planning, moved"})

      assert Repo.reload!(row).sync_state == "locally_modified"
    end
  end

  # Queued edits are what an earlier release wrongly claimed: the queue
  # marked every write it saved as Tymeslot's, so the organiser's edit of
  # somebody else's event hid it from the agenda for good and won its
  # replay the force-write over the owner's own changes.
  describe "whose event a queued edit says it is" do
    test "an edit queued from the grid's write queue leaves somebody else's event theirs", %{
      user: user,
      row: row,
      event: event
    } do
      refute row.created_by_tymeslot

      assert {:ok, _updated} =
               EventEdit.queue_for_retry(user.id, event, %{summary: "Planning, renamed"})

      stored = Repo.reload!(row)
      assert stored.sync_state == "locally_modified"
      assert stored.summary == "Planning, renamed"
      refute stored.created_by_tymeslot
    end

    test "an edit queued after the server refused it leaves somebody else's event theirs", %{
      user: user,
      row: row,
      event: event
    } do
      server_unavailable()

      assert {:error, %{retry: :queued}} =
               EventEdit.update_event(user.id, event, %{summary: "Planning, renamed"})

      stored = Repo.reload!(row)
      assert stored.sync_state == "locally_modified"
      refute stored.created_by_tymeslot
    end

    test "an edit queued for Tymeslot's own event keeps it Tymeslot's", %{user: user, row: row} do
      row = row |> Changeset.change(created_by_tymeslot: true) |> Repo.update!()
      event = ProviderCalendarEventSchema.to_calendar_event(row)

      assert {:ok, _updated} =
               EventEdit.queue_for_retry(user.id, event, %{summary: "Planning, renamed"})

      stored = Repo.reload!(row)
      assert stored.sync_state == "locally_modified"
      assert stored.created_by_tymeslot
    end
  end
end
