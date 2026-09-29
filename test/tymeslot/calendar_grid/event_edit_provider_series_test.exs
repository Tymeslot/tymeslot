defmodule Tymeslot.CalendarGrid.EventEditProviderSeriesTest do
  @moduledoc """
  An edit of every occurrence of a Google or Outlook recurring event, from
  the grid down to the wire.

  The `:calendar_module` seam and the provider API modules are pointed back
  at the runtime modules, so only the HTTP client is mocked: the master is
  read with a `GET`, and written with a `PATCH` carrying only what changed.
  Under `verify_on_exit!` any other request, a `PUT` of the whole occurrence
  included, fails the test.
  """
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :integration

  import Mox

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar.Google.CalendarAPI, as: GoogleAPI
  alias Tymeslot.Integrations.Calendar.Operations
  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI, as: OutlookAPI
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Workers.RefreshOutlookCalendarWorker
  alias Tymeslot.Workers.SyncGoogleCalendarWorker

  setup :verify_on_exit!

  defp swap_env(key, module) do
    previous = Application.get_env(:tymeslot, key)
    Application.put_env(:tymeslot, key, module)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:tymeslot, key, previous),
        else: Application.delete_env(:tymeslot, key)
    end)
  end

  setup do
    swap_env(:calendar_module, Operations)
    swap_env(:google_calendar_api_module, GoogleAPI)
    swap_env(:outlook_calendar_api_module, OutlookAPI)

    %{user: insert(:user)}
  end

  defp insert_integration(user, provider, scope) do
    insert(:calendar_integration,
      user: user,
      provider: provider,
      access_token_encrypted: Encryption.encrypt("valid_token"),
      refresh_token_encrypted: Encryption.encrypt("refresh_token"),
      token_expires_at: DateTime.add(DateTime.utc_now(), 3600),
      oauth_scope: scope
    )
  end

  # Two occurrences of a weekly Monday 09:00 Berlin series, after the change
  # to winter time, and an event of no series.
  defp insert_rows(integration, provider, master_id) do
    row = fn attrs ->
      insert(
        :provider_calendar_event,
        Map.merge(
          %{
            calendar_integration: integration,
            provider: provider,
            provider_calendar_id: "team-calendar",
            summary: "Weekly sync",
            all_day: false,
            timezone: "Europe/Berlin",
            recurring_event_id: master_id,
            sync_state: "synced"
          },
          attrs
        )
      )
    end

    %{
      occurrence:
        row.(%{
          uid: "weekly_20261102T080000Z",
          provider_event_id: "#{master_id}_20261102T080000Z",
          start_at: ~U[2026-11-02 08:00:00.000000Z],
          end_at: ~U[2026-11-02 09:00:00.000000Z]
        }),
      sibling:
        row.(%{
          uid: "weekly_20261109T080000Z",
          provider_event_id: "#{master_id}_20261109T080000Z",
          start_at: ~U[2026-11-09 08:00:00.000000Z],
          end_at: ~U[2026-11-09 09:00:00.000000Z]
        }),
      unrelated:
        row.(%{
          uid: "one-off",
          provider_event_id: "one-off",
          summary: "Sprint review",
          recurring_event_id: nil,
          timezone: nil,
          start_at: ~U[2026-11-03 09:00:00.000000Z],
          end_at: ~U[2026-11-03 10:00:00.000000Z]
        })
    }
  end

  # Answers the master on a GET and records every write; `patch` is the
  # PATCH's answer.
  defp serve_master(master, patch \\ {:ok, 200}) do
    test_pid = self()

    stub(Tymeslot.HTTPClientMock, :request, fn
      :get, url, _body, _headers, _opts ->
        send(test_pid, {:get, url})
        {:ok, %Req.Response{status: 200, body: Jason.encode!(master)}}

      method, url, body, _headers, _opts ->
        send(test_pid, {method, url, body})

        case patch do
          {:ok, status} -> {:ok, %Req.Response{status: status, body: Jason.encode!(master)}}
          {:error, status} -> {:ok, %Req.Response{status: status, body: ~s({"error":{}})}}
        end
    end)
  end

  defp an_hour_later,
    do: %{start_at: ~U[2026-11-02 09:00:00.000000Z], end_at: ~U[2026-11-02 10:00:00.000000Z]}

  defp a_day_later,
    do: %{start_at: ~U[2026-11-03 08:00:00.000000Z], end_at: ~U[2026-11-03 09:00:00.000000Z]}

  describe "every occurrence of a Google series" do
    @google_master %{
      "id" => "series1",
      "summary" => "Weekly sync",
      "start" => %{"dateTime" => "2026-06-01T09:00:00+02:00", "timeZone" => "Europe/Berlin"},
      "end" => %{"dateTime" => "2026-06-01T10:00:00+02:00", "timeZone" => "Europe/Berlin"},
      "recurrence" => ["RRULE:FREQ=WEEKLY;BYDAY=MO", "EXDATE;TZID=Europe/Berlin:20260615T090000"]
    }

    @master_url "https://www.googleapis.com/calendar/v3/calendars/team-calendar/events/series1"

    setup %{user: user} do
      integration = insert_integration(user, "google", "https://www.googleapis.com/auth/calendar")
      Map.put(insert_rows(integration, "google", "series1"), :integration, integration)
    end

    test "a move PATCHes the master on its own wall clock, and never PUTs", %{
      user: user,
      occurrence: occurrence
    } do
      serve_master(@google_master)

      assert {:ok, _updated} =
               CalendarGrid.update_event(user.id, occurrence, an_hour_later(),
                 recurrence_scope: :all
               )

      assert_received {:get, @master_url}
      assert_received {:patch, @master_url <> "?sendUpdates=none", body}
      refute_received {:put, _url, _body}

      sent = Jason.decode!(body)

      assert sent["start"] == %{
               "dateTime" => "2026-06-01T10:00:00",
               "timeZone" => "Europe/Berlin"
             }

      assert sent["end"] == %{"dateTime" => "2026-06-01T11:00:00", "timeZone" => "Europe/Berlin"}

      assert sent["recurrence"] == [
               "RRULE:FREQ=WEEKLY;BYDAY=MO",
               "EXDATE;TZID=Europe/Berlin:20260615T100000"
             ]

      refute Map.has_key?(sent, "summary")
    end

    test "a move to Tuesday carries the series' UNTIL with it", %{
      user: user,
      occurrence: occurrence
    } do
      # Monday 28 December, 09:00 in Berlin, the last occurrence's start.
      serve_master(%{
        @google_master
        | "recurrence" => ["RRULE:FREQ=WEEKLY;BYDAY=MO;UNTIL=20261228T080000Z"]
      })

      assert {:ok, _updated} =
               CalendarGrid.update_event(user.id, occurrence, a_day_later(),
                 recurrence_scope: :all
               )

      assert_received {:patch, @master_url <> "?sendUpdates=none", body}

      assert Jason.decode!(body)["recurrence"] == [
               "RRULE:FREQ=WEEKLY;BYDAY=TU;UNTIL=20261229T080000Z"
             ]
    end

    test "the series' rows are dropped, the rest kept, and a sync requested", %{
      user: user,
      integration: integration,
      occurrence: occurrence,
      sibling: sibling,
      unrelated: unrelated
    } do
      serve_master(@google_master)

      assert {:ok, _updated} =
               CalendarGrid.update_event(user.id, occurrence, %{summary: "Standup"},
                 recurrence_scope: :all
               )

      assert_received {:patch, _url, body}
      assert Jason.decode!(body) == %{"summary" => "Standup"}

      for uid <- [occurrence.uid, sibling.uid] do
        assert ProviderCalendarEventQueries.get_by_uid(integration.id, uid) ==
                 {:error, :not_found}
      end

      assert {:ok, %{summary: "Sprint review"}} =
               ProviderCalendarEventQueries.get_by_uid(integration.id, unrelated.uid)

      assert_enqueued(
        worker: SyncGoogleCalendarWorker,
        args: %{"calendar_integration_id" => integration.id}
      )
    end

    test "a failed write is not queued, leaves the rows and requests no sync", %{
      user: user,
      integration: integration,
      occurrence: occurrence,
      sibling: sibling
    } do
      serve_master(@google_master, {:error, 500})

      assert {:error, %{retry: :not_queued}} =
               CalendarGrid.update_event(user.id, occurrence, %{summary: "Standup"},
                 recurrence_scope: :all
               )

      for uid <- [occurrence.uid, sibling.uid] do
        assert {:ok, %{summary: "Weekly sync", sync_state: "synced"}} =
                 ProviderCalendarEventQueries.get_by_uid(integration.id, uid)
      end

      refute_enqueued(worker: SyncGoogleCalendarWorker)
    end

    test "a move the rule cannot follow is refused after the read and before any write", %{
      user: user,
      integration: integration,
      occurrence: occurrence
    } do
      serve_master(%{@google_master | "recurrence" => ["RRULE:FREQ=MONTHLY;BYDAY=1MO"]})

      assert {:error, %{reason: :rule_pins_occurrences, retry: :not_queued}} =
               CalendarGrid.update_event(
                 user.id,
                 occurrence,
                 %{
                   start_at: ~U[2026-11-03 08:00:00.000000Z],
                   end_at: ~U[2026-11-03 09:00:00.000000Z]
                 },
                 recurrence_scope: :all
               )

      assert_received {:get, @master_url}
      refute_received {:patch, _url, _body}
      assert {:ok, _row} = ProviderCalendarEventQueries.get_by_uid(integration.id, occurrence.uid)
      refute_enqueued(worker: SyncGoogleCalendarWorker)
    end

    # No stub: under `verify_on_exit!` any request would fail the test.
    test "a row naming no master is refused before anything is read", %{
      user: user,
      integration: integration
    } do
      master_row =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          provider: "google",
          uid: "series-master",
          provider_event_id: "series1",
          recurrence_rule: "RRULE:FREQ=WEEKLY;BYDAY=MO",
          start_at: ~U[2026-06-01 07:00:00.000000Z],
          end_at: ~U[2026-06-01 08:00:00.000000Z],
          all_day: false,
          sync_state: "synced"
        )

      assert {:error, %{reason: :unaddressable_occurrence, retry: :not_queued}} =
               CalendarGrid.update_event(user.id, master_row, %{summary: "Standup"},
                 recurrence_scope: :all
               )
    end
  end

  describe "every occurrence of an Outlook series" do
    @outlook_master %{
      "id" => "master-1",
      "type" => "seriesMaster",
      "subject" => "Weekly sync",
      "isAllDay" => false,
      "start" => %{"dateTime" => "2026-06-01T07:00:00.0000000", "timeZone" => "UTC"},
      "end" => %{"dateTime" => "2026-06-01T08:00:00.0000000", "timeZone" => "UTC"},
      "originalStartTimeZone" => "W. Europe Standard Time",
      "recurrence" => %{
        "pattern" => %{"type" => "weekly", "interval" => 1, "daysOfWeek" => ["monday"]},
        "range" => %{"type" => "noEnd", "startDate" => "2026-06-01"}
      }
    }

    @outlook_url "https://graph.microsoft.com/v1.0/me/events/master-1"

    setup %{user: user} do
      integration =
        insert_integration(user, "outlook", "https://graph.microsoft.com/Calendars.ReadWrite")

      Map.put(insert_rows(integration, "outlook", "master-1"), :integration, integration)
    end

    test "a move PATCHes the master in the zone it was created in, rows dropped, sync requested",
         %{user: user, integration: integration, occurrence: occurrence, sibling: sibling} do
      serve_master(@outlook_master)

      assert {:ok, _updated} =
               CalendarGrid.update_event(user.id, occurrence, an_hour_later(),
                 recurrence_scope: :all
               )

      assert_received {:get, @outlook_url}
      assert_received {:patch, @outlook_url, body}

      assert Jason.decode!(body) == %{
               "start" => %{
                 "dateTime" => "2026-06-01T10:00:00",
                 "timeZone" => "W. Europe Standard Time"
               },
               "end" => %{
                 "dateTime" => "2026-06-01T11:00:00",
                 "timeZone" => "W. Europe Standard Time"
               }
             }

      for uid <- [occurrence.uid, sibling.uid] do
        assert ProviderCalendarEventQueries.get_by_uid(integration.id, uid) ==
                 {:error, :not_found}
      end

      assert_enqueued(
        worker: RefreshOutlookCalendarWorker,
        args: %{"calendar_integration_id" => integration.id}
      )
    end

    test "a move to Tuesday carries the series' end date with it", %{
      user: user,
      occurrence: occurrence
    } do
      serve_master(
        put_in(@outlook_master, ["recurrence", "range"], %{
          "type" => "endDate",
          "startDate" => "2026-06-01",
          "endDate" => "2026-12-28"
        })
      )

      assert {:ok, _updated} =
               CalendarGrid.update_event(user.id, occurrence, a_day_later(),
                 recurrence_scope: :all
               )

      assert_received {:patch, @outlook_url, body}

      assert Jason.decode!(body)["recurrence"]["range"] == %{
               "type" => "endDate",
               "startDate" => "2026-06-02",
               "endDate" => "2026-12-29"
             }
    end

    test "a failed write is not queued, leaves the rows and requests no sync", %{
      user: user,
      integration: integration,
      occurrence: occurrence
    } do
      serve_master(@outlook_master, {:error, 500})

      assert {:error, %{retry: :not_queued}} =
               CalendarGrid.update_event(user.id, occurrence, %{summary: "Standup"},
                 recurrence_scope: :all
               )

      assert {:ok, %{summary: "Weekly sync"}} =
               ProviderCalendarEventQueries.get_by_uid(integration.id, occurrence.uid)

      refute_enqueued(worker: RefreshOutlookCalendarWorker)
    end
  end
end
