defmodule Tymeslot.Workers.SyncGoogleCalendarWorkerSweepTest do
  # Events deleted in Google that only a complete windowed listing can reveal:
  # every secondary calendar on every run, and the booking calendar when it
  # bootstraps. The API client is mocked at its behaviour; everything from the
  # worker down to the cache is real.
  use Tymeslot.DataCase, async: false

  @moduletag :workers
  @moduletag :calendar
  @moduletag :integration

  use Oban.Testing, repo: Tymeslot.Repo
  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo
  alias Tymeslot.Workers.SyncGoogleCalendarWorker

  setup :verify_on_exit!

  @work "work@example.com"

  setup do
    integration =
      insert(:calendar_integration,
        provider: "google",
        google_sync_token: "valid-token",
        default_booking_calendar_id: nil,
        calendar_list: [
          %{"id" => "primary", "selected" => true, "name" => "Primary"},
          %{"id" => @work, "selected" => true, "name" => "Work"}
        ]
      )

    %{integration: integration, base: base_time()}
  end

  # A slot a few days ahead, on the hour, so instance stamps are predictable.
  defp base_time do
    DateTime.utc_now()
    |> DateTime.add(3, :day)
    |> Map.merge(%{hour: 9, minute: 0, second: 0, microsecond: {0, 6}})
  end

  defp an_hour_ago, do: DateTime.add(DateTime.utc_now(:microsecond), -3600, :second)

  # A row an earlier sync cached: last written an hour ago.
  defp cached(integration, uid, start_at, attrs \\ []) do
    insert(
      :provider_calendar_event,
      Keyword.merge(
        [
          calendar_integration: integration,
          provider_calendar_id: @work,
          uid: uid,
          provider_event_id: uid,
          start_at: start_at,
          end_at: start_at && DateTime.add(start_at, 3600, :second),
          synced_at: an_hour_ago(),
          updated_at: an_hour_ago()
        ],
        attrs
      )
    )
  end

  defp google_event(id, start_at) do
    %{
      "id" => id,
      "iCalUID" => id,
      "status" => "confirmed",
      "summary" => "Event #{id}",
      "start" => %{"dateTime" => DateTime.to_iso8601(start_at)},
      "end" => %{"dateTime" => DateTime.to_iso8601(DateTime.add(start_at, 3600, :second))}
    }
  end

  defp stamp(datetime), do: Calendar.strftime(datetime, "%Y%m%dT%H%M%SZ")

  # One instance of the series `master`, in the slot the series gave it
  # (`original`), now at `start_at`.
  defp instance(master, original, start_at) do
    %{
      "id" => "#{master}_#{stamp(original)}",
      "iCalUID" => "#{master}@google.com",
      "recurringEventId" => master,
      "originalStartTime" => %{"dateTime" => DateTime.to_iso8601(original)},
      "status" => "confirmed",
      "summary" => "Weekly",
      "start" => %{"dateTime" => DateTime.to_iso8601(start_at)},
      "end" => %{"dateTime" => DateTime.to_iso8601(DateTime.add(start_at, 1800, :second))}
    }
  end

  defp expect_delta(events \\ []) do
    expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
      {:ok, %{events: events, next_sync_token: "next-token"}}
    end)
  end

  defp expect_work_listing(result) do
    expect(GoogleCalendarAPIMock, :list_events, fn _integration, @work, _start, _end ->
      result
    end)
  end

  defp run(integration),
    do: perform_job(SyncGoogleCalendarWorker, %{"calendar_integration_id" => integration.id})

  defp cached_uids(integration) do
    ProviderCalendarEventSchema
    |> where([e], e.calendar_integration_id == ^integration.id)
    |> select([e], e.uid)
    |> Repo.all()
    |> Enum.sort()
  end

  describe "a secondary calendar" do
    test "an event deleted in Google disappears from the cache after the next sync",
         %{integration: integration, base: base} do
      cached(integration, "kept", base)
      cached(integration, "deleted", DateTime.add(base, 1, :day))

      expect_delta()
      expect_work_listing({:ok, [google_event("kept", base)]})

      assert :ok = run(integration)
      assert cached_uids(integration) == ["kept"]
    end

    test "a series retimed in Google leaves only its new occurrences",
         %{integration: integration, base: base} do
      originals = [base, DateTime.add(base, 7, :day)]

      for original <- originals do
        cached(integration, "series@google.com_#{stamp(original)}", original,
          provider_event_id: "series_#{stamp(original)}",
          recurring_event_id: "series"
        )
      end

      # Retimed an hour later: every slot of the series moves, so every
      # instance has a new original start and a new id.
      retimed =
        Enum.map(originals, fn original ->
          moved = DateTime.add(original, 3600, :second)
          instance("series", moved, moved)
        end)

      expect_delta()
      expect_work_listing({:ok, retimed})

      assert :ok = run(integration)

      assert cached_uids(integration) ==
               Enum.map(originals, &"series@google.com_#{stamp(DateTime.add(&1, 3600, :second))}")
    end

    test "rows a failed listing may have left out are all kept",
         %{integration: integration, base: base} do
      cached(integration, "unconfirmed", base)

      expect_delta()
      expect_work_listing({:error, :network_error, "Google returned 500 on page 2"})

      assert {:error, _reason} = run(integration)
      assert cached_uids(integration) == ["unconfirmed"]
    end

    test "rows a listing cut off at the page cap may have left out are all kept",
         %{integration: integration, base: base} do
      cached(integration, "unconfirmed", base)

      expect_delta()
      expect_work_listing({:error, :too_many_pages, "Event listing exceeded 200 pages"})

      assert {:error, _reason} = run(integration)
      assert cached_uids(integration) == ["unconfirmed"]
    end

    test "a calendar skipped for refused credentials is not swept",
         %{integration: integration, base: base} do
      cached(integration, "unconfirmed", base)

      expect_delta()
      expect_work_listing({:error, :unauthorized, "Forbidden"})

      assert :ok = run(integration)
      assert cached_uids(integration) == ["unconfirmed"]
    end

    test "only the listed calendar's rows are swept, and only this integration's",
         %{integration: integration, base: base} do
      cached(integration, "on-unselected-calendar", base,
        provider_calendar_id: "other@example.com"
      )

      other_integration = insert(:calendar_integration, provider: "google")
      cached(other_integration, "on-another-integration", base)

      expect_delta()
      expect_work_listing({:ok, []})

      assert :ok = run(integration)
      assert cached_uids(integration) == ["on-unselected-calendar"]
      assert cached_uids(other_integration) == ["on-another-integration"]
    end
  end

  describe "the booking calendar" do
    test "an incremental run leaves its rows to the sync token's cancellations",
         %{integration: integration, base: base} do
      cached(integration, "primary-row", base, provider_calendar_id: "primary")

      expect_delta()
      expect_work_listing({:ok, []})

      assert :ok = run(integration)
      assert cached_uids(integration) == ["primary-row"]
    end

    test "a bootstrap after an expired sync token sweeps events deleted meanwhile",
         %{integration: integration, base: base} do
      cached(integration, "primary-kept", base, provider_calendar_id: "primary")

      cached(integration, "primary-deleted", DateTime.add(base, 1, :day),
        provider_calendar_id: "primary"
      )

      expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
        {:error, :gone, "Sync token expired"}
      end)

      expect(GoogleCalendarAPIMock, :bootstrap_sync, fn _integration ->
        {:ok, %{events: [google_event("primary-kept", base)], next_sync_token: "fresh"}}
      end)

      expect_work_listing({:ok, []})

      assert :ok = run(integration)
      assert cached_uids(integration) == ["primary-kept"]
    end

    test "the bootstrap sweeps the calendar its rows are filed under",
         %{base: base} do
      integration =
        insert(:calendar_integration,
          provider: "google",
          google_sync_token: nil,
          default_booking_calendar_id: "bookings@example.com",
          calendar_list: []
        )

      cached(integration, "booking-cal-deleted", base,
        provider_calendar_id: "bookings@example.com"
      )

      expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
        {:error, :no_sync_token}
      end)

      expect(GoogleCalendarAPIMock, :bootstrap_sync, fn _integration ->
        {:ok, %{events: [], next_sync_token: "fresh"}}
      end)

      assert :ok = run(integration)
      assert cached_uids(integration) == []
    end
  end

  describe "rows the sweep spares" do
    test "a row written locally while the listing was read",
         %{integration: integration, base: base} do
      expect_delta()

      expect(GoogleCalendarAPIMock, :list_events, fn _integration, @work, _start, _end ->
        # The grid caches an event it has just created, after this listing
        # was read from Google.
        insert(:provider_calendar_event,
          calendar_integration: integration,
          provider_calendar_id: @work,
          uid: "created-in-grid",
          start_at: base,
          end_at: DateTime.add(base, 3600, :second)
        )

        {:ok, []}
      end)

      assert :ok = run(integration)
      assert cached_uids(integration) == ["created-in-grid"]
    end

    test "a local create still queued for the server",
         %{integration: integration, base: base} do
      cached(integration, "queued-create", base, sync_state: "locally_created")

      expect_delta()
      expect_work_listing({:ok, []})

      assert :ok = run(integration)
      assert cached_uids(integration) == ["queued-create"]
    end

    test "a booking's row, whose meeting is left exactly as it was",
         %{integration: integration, base: base} do
      meeting =
        insert(:meeting,
          calendar_integration_id: integration.id,
          uid: "booking-uid",
          start_time: DateTime.truncate(base, :second),
          end_time: base |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
        )

      cached(integration, "booking-uid", base, provider_event_id: "booking-event-id")
      cached(integration, "not-a-booking", base)

      expect_delta()
      expect_work_listing({:ok, []})

      assert :ok = run(integration)
      assert cached_uids(integration) == ["booking-uid"]

      reloaded = Repo.get!(MeetingSchema, meeting.id)
      assert reloaded.status == "confirmed"
      assert reloaded.calendar_sync_status == meeting.calendar_sync_status
    end

    test "rows straddling either edge of the listed window, all-day and timed",
         %{integration: integration} do
      now = DateTime.utc_now()
      past_edge = DateTime.add(now, -ProviderConfig.sync_window_past_days(), :day)
      future_edge = DateTime.add(now, ProviderConfig.sync_window_future_days(), :day)

      # An all-day event is listed by Google against its dates in the
      # calendar's zone, which may put a day on either edge inside the
      # window or outside it: the one ending the day after the past edge, and
      # the one starting on the future edge's day.
      cached(integration, "all-day-past-edge", nil,
        all_day: true,
        start_date: past_edge |> DateTime.to_date() |> Date.add(-1),
        end_date: past_edge |> DateTime.to_date() |> Date.add(1)
      )

      cached(integration, "all-day-future-edge", nil,
        all_day: true,
        start_date: DateTime.to_date(future_edge),
        end_date: future_edge |> DateTime.to_date() |> Date.add(1)
      )

      cached(integration, "timed-past-edge", DateTime.add(past_edge, -3, :hour),
        end_at: DateTime.add(past_edge, 3, :hour)
      )

      cached(integration, "timed-future-edge", DateTime.add(future_edge, -3, :hour),
        end_at: DateTime.add(future_edge, 3, :hour)
      )

      # Anchors the test: a row well inside the window is swept, so the
      # survivors survive because of where they sit and not because nothing
      # was swept at all.
      cached(integration, "inside", DateTime.add(now, 2, :day))

      expect_delta()
      expect_work_listing({:ok, []})

      assert :ok = run(integration)

      assert cached_uids(integration) ==
               Enum.sort([
                 "all-day-future-edge",
                 "all-day-past-edge",
                 "timed-future-edge",
                 "timed-past-edge"
               ])
    end
  end
end
