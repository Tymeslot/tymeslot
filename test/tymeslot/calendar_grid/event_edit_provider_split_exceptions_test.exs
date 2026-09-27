defmodule Tymeslot.CalendarGrid.EventEditProviderSplitExceptionsTest do
  @moduledoc """
  An organiser edits one occurrence of a Google or Outlook recurring event
  and every following one, in a series where later occurrences were edited
  or cancelled on their own. Those occurrences are separate from the
  series' rule on both providers, and the provider drops them once the
  original series is ended before them, so they are read before the split
  and written again to the new series: an edited one keeps its own changes,
  and a cancelled one stays cancelled.

  As in `Tymeslot.CalendarGrid.EventEditProviderSplitTest`, only the HTTP
  client is mocked, and every request is recorded in the order it was made.
  """
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :integration

  import ExUnit.CaptureLog
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

  # The occurrence of 2 November of a weekly Monday 09:00 Berlin series,
  # which the tests split at.
  defp insert_occurrence(integration, provider, master_id, calendar_id, metadata \\ %{}) do
    insert(:provider_calendar_event,
      provider_metadata: metadata,
      calendar_integration: integration,
      provider: provider,
      provider_calendar_id: calendar_id,
      summary: "Weekly sync",
      all_day: false,
      timezone: "Europe/Berlin",
      recurring_event_id: master_id,
      sync_state: "synced",
      uid: "weekly_20261102T080000Z",
      provider_event_id: "#{master_id}_20261102T080000Z",
      start_at: ~U[2026-11-02 08:00:00.000000Z],
      end_at: ~U[2026-11-02 09:00:00.000000Z]
    )
  end

  # Answers each request through `answer`, by method and URL, and records it.
  defp serve(answer) do
    test_pid = self()

    stub(Tymeslot.HTTPClientMock, :request, fn method, url, body, _headers, _opts ->
      send(test_pid, {:request, method, url, body})

      case answer.(method, url) do
        {status, nil} -> {:ok, %Req.Response{status: status, body: ""}}
        {status, reply} -> {:ok, %Req.Response{status: status, body: Jason.encode!(reply)}}
      end
    end)
  end

  defp requests do
    receive do
      {:request, method, url, body} -> [{method, url, body} | requests()]
    after
      0 -> []
    end
  end

  # The writes to the new series' own occurrences, by method and path.
  defp writes_to(sent, prefix) do
    for {method, url, body} <- sent,
        method in [:patch, :delete],
        path = url |> URI.parse() |> Map.get(:path),
        String.contains?(path, prefix) do
      {method, path, if(body in [nil, ""], do: nil, else: Jason.decode!(body))}
    end
  end

  describe "a Google series with later occurrences changed on their own" do
    @events_path "/calendar/v3/calendars/team-calendar/events"

    @master %{
      "id" => "series1",
      "iCalUID" => "series1@google.com",
      "summary" => "Weekly sync",
      "start" => %{"dateTime" => "2026-06-01T09:00:00+02:00", "timeZone" => "Europe/Berlin"},
      "end" => %{"dateTime" => "2026-06-01T10:00:00+02:00", "timeZone" => "Europe/Berlin"},
      "recurrence" => ["RRULE:FREQ=WEEKLY;BYDAY=MO;COUNT=30"]
    }

    # 9 November moved to 14:00 and renamed; 16 November cancelled; 23
    # November renamed only; 26 October renamed, before the split.
    defp google_exception(day, attrs) do
      Map.merge(
        %{
          "id" => "series1_202611#{day}T080000Z",
          "iCalUID" => "series1@google.com",
          "recurringEventId" => "series1",
          "status" => "confirmed",
          "summary" => "Weekly sync",
          "originalStartTime" => %{
            "dateTime" => "2026-11-#{day}T09:00:00+01:00",
            "timeZone" => "Europe/Berlin"
          },
          "start" => %{
            "dateTime" => "2026-11-#{day}T09:00:00+01:00",
            "timeZone" => "Europe/Berlin"
          },
          "end" => %{"dateTime" => "2026-11-#{day}T10:00:00+01:00", "timeZone" => "Europe/Berlin"}
        },
        attrs
      )
    end

    defp series_events do
      [
        @master,
        google_exception("09", %{
          "summary" => "Planning",
          "start" => %{"dateTime" => "2026-11-09T14:00:00+01:00", "timeZone" => "Europe/Berlin"},
          "end" => %{"dateTime" => "2026-11-09T15:00:00+01:00", "timeZone" => "Europe/Berlin"}
        }),
        %{
          "id" => "series1_20261116T080000Z",
          "recurringEventId" => "series1",
          "status" => "cancelled",
          "originalStartTime" => %{
            "dateTime" => "2026-11-16T09:00:00+01:00",
            "timeZone" => "Europe/Berlin"
          }
        },
        google_exception("23", %{"summary" => "Retro"}),
        google_exception("26", %{
          "id" => "series1_20261026T080000Z",
          "summary" => "Old",
          "originalStartTime" => %{
            "dateTime" => "2026-10-26T09:00:00+01:00",
            "timeZone" => "Europe/Berlin"
          }
        })
      ]
    end

    defp google(instance_status \\ 200) do
      fn method, url ->
        path = URI.parse(url).path

        cond do
          method == :get and path == @events_path -> {200, %{"items" => series_events()}}
          method == :get -> {200, @master}
          method == :post -> {200, %{"id" => "tail1", "iCalUID" => "tail1@google.com"}}
          String.contains?(path, "/tail1_") and instance_status != 200 -> {instance_status, %{}}
          method == :patch -> {200, @master}
          method == :delete -> {204, nil}
        end
      end
    end

    setup %{user: user} do
      integration = insert_integration(user, "google", "https://www.googleapis.com/auth/calendar")
      occurrence = insert_occurrence(integration, "google", "series1", "team-calendar")
      %{integration: integration, occurrence: occurrence}
    end

    test "the new series keeps each change, moved with the series, and the cancellation", %{
      user: user,
      occurrence: occurrence
    } do
      serve(google())

      # An hour later, from 09:00 to 10:00 Berlin, and renamed.
      assert {:ok, _updated} =
               CalendarGrid.update_event(
                 user.id,
                 occurrence,
                 %{
                   start_at: ~U[2026-11-02 09:00:00.000000Z],
                   end_at: ~U[2026-11-02 10:00:00.000000Z],
                   summary: "Standup"
                 },
                 recurrence_scope: :following
               )

      sent = requests()

      # Read before anything is written; carried once the split is written.
      assert Enum.map(sent, &elem(&1, 0)) == [:get, :get, :post, :patch, :patch, :delete, :patch]

      # Each occurrence of the new series is its original start an hour on,
      # in UTC, after the tail's id.
      assert writes_to(sent, "/tail1_") == [
               {:patch, @events_path <> "/tail1_20261109T090000Z",
                %{
                  "summary" => "Planning",
                  "start" => %{"dateTime" => "2026-11-09T15:00:00", "timeZone" => "Europe/Berlin"},
                  "end" => %{"dateTime" => "2026-11-09T16:00:00", "timeZone" => "Europe/Berlin"}
                }},
               {:delete, @events_path <> "/tail1_20261116T090000Z", nil},
               {:patch, @events_path <> "/tail1_20261123T090000Z", %{"summary" => "Retro"}}
             ]
    end

    test "a change that cannot be carried is logged, and the edit still succeeds", %{
      user: user,
      integration: integration,
      occurrence: occurrence
    } do
      serve(google(500))

      log =
        capture_log(fn ->
          assert {:ok, _updated} =
                   CalendarGrid.update_event(user.id, occurrence, %{summary: "Standup"},
                     recurrence_scope: :following
                   )
        end)

      assert log =~ "Could not carry every occurrence changed on its own"

      # The split itself stands: the series' rows go and a sync is asked for.
      assert ProviderCalendarEventQueries.get_by_uid(integration.id, occurrence.uid) ==
               {:error, :not_found}

      assert_enqueued(
        worker: SyncGoogleCalendarWorker,
        args: %{"calendar_integration_id" => integration.id}
      )

      # Nor is the new series taken back.
      deleted = for {:delete, url, _body} <- requests(), do: URI.parse(url).path
      assert deleted == [@events_path <> "/tail1_20261116T080000Z"]
    end
  end

  describe "an Outlook series with later occurrences changed on their own" do
    @zone "W. Europe Standard Time"

    @outlook_master %{
      "id" => "master-1",
      "iCalUId" => "040000008200E00074C5B7101A82E008",
      "type" => "seriesMaster",
      "subject" => "Weekly sync",
      "isAllDay" => false,
      "start" => %{"dateTime" => "2026-06-01T07:00:00.0000000", "timeZone" => "UTC"},
      "end" => %{"dateTime" => "2026-06-01T08:00:00.0000000", "timeZone" => "UTC"},
      "originalStartTimeZone" => @zone,
      "recurrence" => %{
        "pattern" => %{"type" => "weekly", "interval" => 1, "daysOfWeek" => ["monday"]},
        "range" => %{
          "type" => "numbered",
          "startDate" => "2026-06-01",
          "numberOfOccurrences" => 30
        }
      }
    }

    # 9 November renamed and moved to 14:00 Berlin; 16 November cancelled.
    @exceptions %{
      "id" => "master-1",
      "exceptionOccurrences" => [
        %{
          "id" => "exception-9",
          "type" => "exception",
          "subject" => "Planning",
          "isAllDay" => false,
          "originalStart" => "2026-11-09T08:00:00Z",
          "start" => %{"dateTime" => "2026-11-09T13:00:00.0000000", "timeZone" => "UTC"},
          "end" => %{"dateTime" => "2026-11-09T14:00:00.0000000", "timeZone" => "UTC"}
        }
      ],
      "cancelledOccurrences" => ["OID.master-1.2026-11-16"]
    }

    # The new series' occurrences, as Graph lists them around any date.
    @tail_instances %{
      "value" =>
        for day <- ~w(09 16 23) do
          %{
            "id" => "tail-occurrence-#{day}",
            "type" => "occurrence",
            "seriesMasterId" => "tail-1",
            "originalStart" => "2026-11-#{day}T08:00:00Z",
            "start" => %{"dateTime" => "2026-11-#{day}T08:00:00.0000000", "timeZone" => "UTC"},
            "end" => %{"dateTime" => "2026-11-#{day}T09:00:00.0000000", "timeZone" => "UTC"}
          }
        end
    }

    defp outlook do
      fn method, url ->
        %URI{path: path, query: query} = URI.parse(url)

        cond do
          method == :get and path == "/v1.0/me/events/master-1/calendar" ->
            {200, %{"id" => "team-calendar"}}

          method == :get and path == "/v1.0/me/events/master-1" and is_binary(query) ->
            {200, @exceptions}

          method == :get and path == "/v1.0/me/events/tail-1/instances" ->
            {200, @tail_instances}

          method == :get ->
            {200, @outlook_master}

          method == :post ->
            {201, %{"id" => "tail-1", "iCalUId" => "040000008200E00074C5B7101A82E009"}}

          method == :patch ->
            {200, %{"id" => Path.basename(path)}}

          method == :delete ->
            {204, nil}
        end
      end
    end

    setup %{user: user} do
      integration =
        insert_integration(user, "outlook", "https://graph.microsoft.com/Calendars.ReadWrite")

      %{
        occurrence:
          insert_occurrence(integration, "outlook", "master-1", "primary", %{
            "type" => "occurrence"
          })
      }
    end

    test "the new series keeps the edited occurrence's change, and the cancelled one stays cancelled",
         %{user: user, occurrence: occurrence} do
      serve(outlook())

      assert {:ok, _updated} =
               CalendarGrid.update_event(user.id, occurrence, %{summary: "Standup"},
                 recurrence_scope: :following
               )

      sent = requests()

      # The exceptions are read before the new series is created.
      assert Enum.find_index(sent, &String.contains?(elem(&1, 1), "exceptionOccurrences")) <
               Enum.find_index(sent, &(elem(&1, 0) == :post))

      assert writes_to(sent, "/tail-occurrence-") == [
               {:patch, "/v1.0/me/events/tail-occurrence-09",
                %{
                  "subject" => "Planning",
                  "start" => %{"dateTime" => "2026-11-09T14:00:00", "timeZone" => @zone},
                  "end" => %{"dateTime" => "2026-11-09T15:00:00", "timeZone" => @zone}
                }},
               {:delete, "/v1.0/me/events/tail-occurrence-16", nil}
             ]

      assert_enqueued(worker: RefreshOutlookCalendarWorker)
    end
  end
end
