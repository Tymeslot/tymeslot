defmodule Tymeslot.Workers.ColourWriteBackWorkerTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :workers

  import Mox

  setup :verify_on_exit!

  alias Ecto.Changeset
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.ColourOverrideQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Repo
  alias Tymeslot.Workers.ColourWriteBackWorker

  setup do
    user = insert(:user)
    integration = insert(:calendar_integration, user: user, provider: "google")
    %{user: user, integration: integration}
  end

  defp cached_event(integration, attrs) do
    defaults = [
      calendar_integration: integration,
      uid: "uid-1",
      summary: "Meeting",
      provider: integration.provider,
      provider_event_id: "pid-1",
      provider_calendar_id: "work",
      raw_ical: "BEGIN:VEVENT\nUID:uid-1\nRRULE:FREQ=WEEKLY\nEND:VEVENT",
      all_day: false,
      start_at: ~U[2026-07-03 10:00:00Z],
      end_at: ~U[2026-07-03 11:00:00Z]
    ]

    insert(:provider_calendar_event, Keyword.merge(defaults, attrs))
  end

  describe "enqueue via the Calendar context" do
    test "set_event_colour enqueues a write-back", %{user: user, integration: integ} do
      {:ok, _override} =
        Calendar.set_event_colour(user.id, {:external, integ.id, "uid-1"}, "blueberry")

      assert_enqueued(
        worker: ColourWriteBackWorker,
        args: %{
          "integration_id" => integ.id,
          "uid" => "uid-1",
          "user_id" => user.id,
          "colour" => "blueberry"
        }
      )
    end

    test "clear_event_colour enqueues a write-back that clears the colour", %{
      user: user,
      integration: integ
    } do
      :ok = Calendar.clear_event_colour(user.id, {:external, integ.id, "uid-1"})

      assert_enqueued(
        worker: ColourWriteBackWorker,
        args: %{"integration_id" => integ.id, "uid" => "uid-1", "colour" => nil}
      )
    end

    test "a clear replaces a write-back of the old colour still waiting", %{
      user: user,
      integration: integ
    } do
      target = {:external, integ.id, "uid-1"}
      {:ok, _override} = Calendar.set_event_colour(user.id, target, "blueberry")
      :ok = Calendar.clear_event_colour(user.id, target)

      assert [%{args: %{"colour" => nil}}] = all_enqueued(worker: ColourWriteBackWorker)
    end

    test "clear_event_colour clears the cached event's colour at once", %{
      user: user,
      integration: integ
    } do
      cached_event(integ, uid: "uid-1", colour: "blueberry")
      :ok = Calendar.clear_event_colour(user.id, {:external, integ.id, "uid-1"})

      assert {:ok, %{colour: nil}} =
               ProviderCalendarEventQueries.get_by_uid(integ.id, "uid-1")
    end
  end

  describe "perform/1" do
    test "pushes only the colour to the provider, never a full-field payload", %{
      user: user,
      integration: integ
    } do
      cached_event(integ, uid: "uid-1")

      {:ok, _override} =
        ColourOverrideQueries.set_external(user.id, integ.id, "uid-1", "blueberry")

      expect(Tymeslot.CalendarMock, :update_event, fn "uid-1", event_data, {integ_id, user_id} ->
        assert event_data.colour_only == true
        assert event_data.colour == "blueberry"
        assert event_data.calendar_id == "work"
        assert event_data.provider_event_id == "pid-1"
        assert event_data.raw_ical =~ "RRULE:FREQ=WEEKLY"
        # Timing/summary/description/location must NOT be sent — a full-field
        # payload would wipe recurrence/attendees/alarms on a full replace.
        refute Map.has_key?(event_data, :summary)
        refute Map.has_key?(event_data, :start_time)
        refute Map.has_key?(event_data, :description)
        assert integ_id == integ.id
        assert user_id == user.id
        :ok
      end)

      assert :ok =
               perform_job(ColourWriteBackWorker, %{
                 "integration_id" => integ.id,
                 "uid" => "uid-1",
                 "user_id" => user.id,
                 "colour" => "blueberry"
               })
    end

    test "writes the colour the override holds when it runs, whatever it was asked", %{
      user: user,
      integration: integ
    } do
      cached_event(integ, uid: "uid-1")
      {:ok, _override} = ColourOverrideQueries.set_external(user.id, integ.id, "uid-1", "grape")

      expect(Tymeslot.CalendarMock, :update_event, fn "uid-1", %{colour: "grape"}, _context ->
        :ok
      end)

      assert :ok =
               perform_job(ColourWriteBackWorker, %{
                 "integration_id" => integ.id,
                 "uid" => "uid-1",
                 "user_id" => user.id,
                 "colour" => "blueberry"
               })

      # The override still holds the colour written, so nothing follows.
      refute_enqueued(worker: ColourWriteBackWorker)
    end

    test "a clear made while a write-back runs gets a job of its own, and the last write clears",
         %{user: user, integration: integ} do
      cached_event(integ, uid: "uid-1")
      target = {:external, integ.id, "uid-1"}
      {:ok, _override} = Calendar.set_event_colour(user.id, target, "blueberry")

      # The set's job has started: it is no longer one a new enqueue may rewrite.
      [running] = all_enqueued(worker: ColourWriteBackWorker)
      running |> Changeset.change(state: "executing") |> Repo.update!()

      :ok = Calendar.clear_event_colour(user.id, target)

      assert [%{args: %{"colour" => nil}} = clearing] =
               all_enqueued(worker: ColourWriteBackWorker)

      refute clearing.id == running.id

      test_pid = self()

      stub(Tymeslot.CalendarMock, :update_event, fn "uid-1", %{colour: colour}, _context ->
        send(test_pid, {:wrote, colour})
        :ok
      end)

      # Whichever of the two runs, it writes what the organiser wants now.
      assert :ok = perform_job(ColourWriteBackWorker, running.args)
      assert :ok = perform_job(ColourWriteBackWorker, clearing.args)
      assert_received {:wrote, nil}
      assert_received {:wrote, nil}
    end

    test "a write that lands after a newer colour was written queues one more job, which writes the newer colour",
         %{user: user, integration: integ} do
      cached_event(integ, uid: "uid-1")

      {:ok, _override} =
        ColourOverrideQueries.set_external(user.id, integ.id, "uid-1", "blueberry")

      args = %{"integration_id" => integ.id, "uid" => "uid-1", "user_id" => user.id}
      test_pid = self()

      # While the first job's blueberry request is in flight, the organiser
      # picks grape and a second job reads it and finishes first.
      stub(Tymeslot.CalendarMock, :update_event, fn "uid-1", %{colour: colour}, _context ->
        if colour == "blueberry" do
          {:ok, _override} =
            ColourOverrideQueries.set_external(user.id, integ.id, "uid-1", "grape")

          assert :ok = perform_job(ColourWriteBackWorker, Map.put(args, "colour", "grape"))
        end

        send(test_pid, {:wrote, colour})
        :ok
      end)

      assert :ok = perform_job(ColourWriteBackWorker, Map.put(args, "colour", "blueberry"))
      assert_received {:wrote, "grape"}
      assert_received {:wrote, "blueberry"}

      assert [%{args: %{"colour" => "grape"} = follow_up}] =
               all_enqueued(worker: ColourWriteBackWorker)

      assert :ok = perform_job(ColourWriteBackWorker, follow_up)
      assert_received {:wrote, "grape"}
      refute_received {:wrote, _colour}
      assert [_only_the_follow_up] = all_enqueued(worker: ColourWriteBackWorker)
    end

    test "a clear on an Outlook event leaves its cached colour and queues nothing", %{
      user: user
    } do
      outlook = insert(:calendar_integration, user: user, provider: "outlook")
      cached_event(outlook, uid: "uid-o", colour: "blueberry")
      target = {:external, outlook.id, "uid-o"}
      {:ok, _override} = ColourOverrideQueries.set_external(user.id, outlook.id, "uid-o", "grape")

      :ok = Calendar.clear_event_colour(user.id, target)

      assert Calendar.overrides_for(user.id) == %{}

      assert {:ok, %{colour: "blueberry"}} =
               ProviderCalendarEventQueries.get_by_uid(outlook.id, "uid-o")

      refute_enqueued(worker: ColourWriteBackWorker)
    end

    test "a cleared colour is pushed as no colour, the colour alone", %{
      user: user,
      integration: integ
    } do
      cached_event(integ, uid: "uid-1")

      expect(Tymeslot.CalendarMock, :update_event, fn "uid-1", event_data, _context ->
        assert %{colour_only: true, colour: nil} = event_data
        refute Map.has_key?(event_data, :summary)
        :ok
      end)

      assert :ok =
               perform_job(ColourWriteBackWorker, %{
                 "integration_id" => integ.id,
                 "uid" => "uid-1",
                 "user_id" => user.id,
                 "colour" => nil
               })
    end

    test "threads the cached ETag into the payload for a conditional write", %{
      user: user,
      integration: integ
    } do
      cached_event(integ, uid: "uid-1", etag: "\"srv-etag-42\"")

      expect(Tymeslot.CalendarMock, :update_event, fn "uid-1", event_data, _context ->
        # The CalDAV path uses this as the If-Match precondition so a colour
        # PUT against a server-edited event 412s and Oban retries, rather than
        # reverting the edit to our stale raw_ical snapshot.
        assert event_data.etag == "\"srv-etag-42\""
        :ok
      end)

      assert :ok =
               perform_job(ColourWriteBackWorker, %{
                 "integration_id" => integ.id,
                 "uid" => "uid-1",
                 "user_id" => user.id,
                 "colour" => "blueberry"
               })
    end

    test "returns an error so Oban retries when the provider write fails", %{
      user: user,
      integration: integ
    } do
      cached_event(integ, uid: "uid-1")

      expect(Tymeslot.CalendarMock, :update_event, fn "uid-1", _event_data, _context ->
        {:error, :read_only}
      end)

      assert {:error, :read_only} =
               perform_job(ColourWriteBackWorker, %{
                 "integration_id" => integ.id,
                 "uid" => "uid-1",
                 "user_id" => user.id,
                 "colour" => "blueberry"
               })
    end

    test "discards for an outlook event (no per-event colour)", %{user: user} do
      integration = insert(:calendar_integration, user: user, provider: "outlook")
      cached_event(integration, uid: "uid-o", provider: "outlook")

      assert {:discard, :provider_has_no_event_colour} =
               perform_job(ColourWriteBackWorker, %{
                 "integration_id" => integration.id,
                 "uid" => "uid-o",
                 "user_id" => user.id,
                 "colour" => "blueberry"
               })
    end

    test "discards when the event is no longer cached", %{user: user, integration: integ} do
      assert {:discard, :event_not_cached} =
               perform_job(ColourWriteBackWorker, %{
                 "integration_id" => integ.id,
                 "uid" => "missing",
                 "user_id" => user.id,
                 "colour" => "blueberry"
               })
    end
  end

  describe "perform/1 before a sync has filled raw_ical" do
    # A CalDAV event created from the grid is cached with raw_ical NULL by
    # design, for the first read to fill. A colour set before that sync has no
    # document to patch, which is recoverable rather than a failure: spending
    # the attempts against a column only a sync can fill discards the write.
    test "snoozes rather than erroring", %{user: user, integration: integ} do
      cached_event(integ, uid: "uid-1", raw_ical: nil)

      expect(Tymeslot.CalendarMock, :update_event, fn "uid-1", _event_data, _context ->
        {:error, :raw_ical_unavailable}
      end)

      assert {:snooze, seconds} =
               perform_job(ColourWriteBackWorker, %{
                 "integration_id" => integ.id,
                 "uid" => "uid-1",
                 "user_id" => user.id,
                 "colour" => "blueberry"
               })

      # Longer than the slowest CalDAV sync cadence (Tier 3, 3600s), or the
      # snooze lands before anything could have filled the column.
      assert seconds > 3600
    end

    test "gives up once the snoozes have covered a full day", %{user: user, integration: integ} do
      cached_event(integ, uid: "uid-1", raw_ical: nil)

      expect(Tymeslot.CalendarMock, :update_event, fn "uid-1", _event_data, _context ->
        {:error, :raw_ical_unavailable}
      end)

      assert {:discard, :raw_ical_never_synced} =
               perform_job(
                 ColourWriteBackWorker,
                 %{
                   "integration_id" => integ.id,
                   "uid" => "uid-1",
                   "user_id" => user.id,
                   "colour" => "blueberry"
                 },
                 meta: %{"snoozed" => 16}
               )
    end

    test "writes through once a sync has populated the column", %{
      user: user,
      integration: integ
    } do
      cached_event(integ, uid: "uid-1", raw_ical: "BEGIN:VEVENT\nUID:uid-1\nEND:VEVENT")

      expect(Tymeslot.CalendarMock, :update_event, fn "uid-1", event_data, _context ->
        assert event_data.raw_ical =~ "UID:uid-1"
        :ok
      end)

      assert :ok =
               perform_job(ColourWriteBackWorker, %{
                 "integration_id" => integ.id,
                 "uid" => "uid-1",
                 "user_id" => user.id,
                 "colour" => "blueberry"
               })
    end
  end
end
