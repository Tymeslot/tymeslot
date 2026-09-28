defmodule Tymeslot.CalendarGrid.SeriesCarryProviderTest do
  @moduledoc """
  What a Google or Outlook series keeps of what only Tymeslot knows about it
  (its video and the organiser's colour overrides) through an edit of every
  occurrence, a split, and a move to another calendar.

  Edits travel down to the HTTP client, as in
  `Tymeslot.CalendarGrid.EventEditProviderSplitTest`; moves are driven
  through a writer handed to `SeriesTransfer.move/4`, as in
  `Tymeslot.CalendarGrid.SeriesTransferTest`. The sync is simulated by
  inserting the rows it caches, and `Tymeslot.Workers.SeriesVideoWorker` is
  then run as Oban would run it.
  """
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :video
  @moduletag :integration

  import Mox

  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.EventVideoRoomQueries
  alias Tymeslot.CalendarGrid.SeriesTransfer
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.ColourOverrideQueries
  alias Tymeslot.Integrations.Calendar.Google.CalendarAPI, as: GoogleAPI
  alias Tymeslot.Integrations.Calendar.Operations
  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI, as: OutlookAPI
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Workers.SeriesVideoWorker

  setup :verify_on_exit!

  @link "https://video.example.com/join/weekly-sync"

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

    user = insert(:user)
    %{user: user, video: insert(:video_integration, user: user, provider: "mirotalk")}
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

  # A row of a weekly Monday 09:00 Berlin series as the sync caches it, with
  # the series' video.
  defp series_row(integration, video, uid, master_id, start_at, attrs \\ %{}) do
    insert(
      :provider_calendar_event,
      Map.merge(
        %{
          calendar_integration: integration,
          provider: integration.provider,
          provider_calendar_id: "team-calendar",
          uid: uid,
          provider_event_id: "#{master_id}_#{uid}",
          recurring_event_id: master_id,
          summary: "Weekly sync",
          description: "Join video call: #{@link}",
          start_at: start_at,
          end_at: DateTime.add(start_at, 3600, :second),
          all_day: false,
          timezone: "Europe/Berlin",
          video_link: @link,
          video_integration_id: video.id,
          sync_state: "synced"
        },
        attrs
      )
    )
  end

  # A row the sync caches for the series named by `master_id`, with no video.
  defp synced_row(integration, uid, master_id, start_at) do
    insert(:provider_calendar_event,
      calendar_integration: integration,
      provider: integration.provider,
      provider_calendar_id: "team-calendar",
      uid: uid,
      provider_event_id: "#{master_id}_#{uid}",
      recurring_event_id: master_id,
      summary: "Weekly sync",
      start_at: start_at,
      end_at: DateTime.add(start_at, 3600, :second),
      all_day: false,
      sync_state: "synced"
    )
  end

  defp serve(answer) do
    stub(Tymeslot.HTTPClientMock, :request, fn method, url, _body, _headers, _opts ->
      case answer.(method, url) do
        {status, nil} -> {:ok, %Req.Response{status: status, body: ""}}
        {status, reply} -> {:ok, %Req.Response{status: status, body: Jason.encode!(reply)}}
      end
    end)
  end

  defp run_video_jobs do
    [worker: SeriesVideoWorker]
    |> all_enqueued()
    |> Enum.map(&perform_job(SeriesVideoWorker, &1.args))
  end

  defp video_of(integration, uid) do
    {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, uid)
    {row.video_integration_id, row.video_link}
  end

  defp colour(user, integration, uid, colour),
    do:
      {:ok, _override} = ColourOverrideQueries.set_external(user.id, integration.id, uid, colour)

  defp colours(user), do: Calendar.overrides_for(user.id)

  describe "a Google series" do
    @google_master %{
      "id" => "series1",
      "iCalUID" => "series1@google.com",
      "etag" => "\"3181\"",
      "summary" => "Weekly sync",
      "start" => %{"dateTime" => "2026-06-01T09:00:00+02:00", "timeZone" => "Europe/Berlin"},
      "end" => %{"dateTime" => "2026-06-01T10:00:00+02:00", "timeZone" => "Europe/Berlin"},
      "recurrence" => ["RRULE:FREQ=WEEKLY;BYDAY=MO;COUNT=30"]
    }

    setup %{user: user, video: video} do
      integration = insert_integration(user, "google", "https://www.googleapis.com/auth/calendar")

      %{
        integration: integration,
        # Summer time, then winter time: 09:00 in Berlin is 07:00 and 08:00 UTC.
        first:
          series_row(
            integration,
            video,
            "series1@google.com_20260601T070000Z",
            "series1",
            ~U[2026-06-01 07:00:00Z]
          ),
        occurrence:
          series_row(
            integration,
            video,
            "series1@google.com_20261102T080000Z",
            "series1",
            ~U[2026-11-02 08:00:00Z]
          )
      }
    end

    defp google do
      fn
        :get, _url -> {200, @google_master}
        :post, _url -> {200, %{"id" => "tail1", "iCalUID" => "tail1@google.com"}}
        :patch, _url -> {200, @google_master}
        :delete, _url -> {204, nil}
      end
    end

    test "an edit of every occurrence an hour later keeps the video and moves the colours", %{
      user: user,
      video: video,
      integration: integration,
      first: first,
      occurrence: occurrence
    } do
      colour(user, integration, first.uid, "sage")
      colour(user, integration, occurrence.uid, "grape")
      serve(google())

      assert {:ok, _updated} =
               CalendarGrid.update_event(
                 user.id,
                 occurrence,
                 %{start_at: ~U[2026-11-02 09:00:00Z], end_at: ~U[2026-11-02 10:00:00Z]},
                 recurrence_scope: :all
               )

      # 10:00 in Berlin on both sides of the change of the clocks.
      assert colours(user) == %{
               {:external, integration.id, "series1@google.com_20260601T080000Z"} => "sage",
               {:external, integration.id, "series1@google.com_20261102T090000Z"} => "grape"
             }

      synced =
        synced_row(
          integration,
          "series1@google.com_20261109T090000Z",
          "series1",
          ~U[2026-11-09 09:00:00Z]
        )

      assert [:ok] = run_video_jobs()
      assert video_of(integration, synced.uid) == {video.id, @link}
    end

    test "a split keeps the video on both halves and moves the following colours", %{
      user: user,
      video: video,
      integration: integration,
      first: first,
      occurrence: occurrence
    } do
      colour(user, integration, first.uid, "sage")
      colour(user, integration, occurrence.uid, "grape")
      serve(google())

      assert {:ok, _updated} =
               CalendarGrid.update_event(
                 user.id,
                 occurrence,
                 %{
                   summary: "Standup",
                   start_at: ~U[2026-11-02 09:00:00Z],
                   end_at: ~U[2026-11-02 10:00:00Z]
                 },
                 recurrence_scope: :following
               )

      assert colours(user) == %{
               {:external, integration.id, first.uid} => "sage",
               {:external, integration.id, "tail1@google.com_20261102T090000Z"} => "grape"
             }

      head = synced_row(integration, first.uid, "series1", ~U[2026-06-01 07:00:00Z])

      tail =
        synced_row(
          integration,
          "tail1@google.com_20261109T090000Z",
          "tail1",
          ~U[2026-11-09 09:00:00Z]
        )

      assert [:ok, :ok] = run_video_jobs()
      assert video_of(integration, head.uid) == {video.id, @link}
      assert video_of(integration, tail.uid) == {video.id, @link}
    end

    test "a move to another Google account's calendar takes the video and the colours", %{
      user: user,
      video: video,
      integration: integration,
      occurrence: occurrence
    } do
      colour(user, integration, occurrence.uid, "grape")
      destination = insert(:calendar_integration, user: user, provider: "google")

      written = %{uid: "moved@google.com", id: "moved1", calendar_id: "team", source: :removed}

      assert {:ok, _moved} =
               SeriesTransfer.move(user.id, occurrence, %{integration: destination},
                 writer: fn :google, _transfer -> {:ok, written} end
               )

      assert colours(user) == %{
               {:external, destination.id, "moved@google.com_20261102T080000Z"} => "grape"
             }

      moved =
        synced_row(
          destination,
          "moved@google.com_20261102T080000Z",
          "moved1",
          ~U[2026-11-02 08:00:00Z]
        )

      assert [:ok] = run_video_jobs()
      assert video_of(destination, moved.uid) == {video.id, @link}
    end
  end

  describe "an Outlook series" do
    @outlook_master %{
      "id" => "master-1",
      "iCalUId" => "040000008200E00074C5B7101A82E008",
      "type" => "seriesMaster",
      "subject" => "Weekly sync",
      "isAllDay" => false,
      "isOnlineMeeting" => false,
      "start" => %{"dateTime" => "2026-06-01T07:00:00.0000000", "timeZone" => "UTC"},
      "end" => %{"dateTime" => "2026-06-01T08:00:00.0000000", "timeZone" => "UTC"},
      "originalStartTimeZone" => "W. Europe Standard Time",
      "recurrence" => %{
        "pattern" => %{"type" => "weekly", "interval" => 1, "daysOfWeek" => ["monday"]},
        "range" => %{
          "type" => "numbered",
          "startDate" => "2026-06-01",
          "numberOfOccurrences" => 30
        }
      }
    }

    setup %{user: user, video: video} do
      integration =
        insert_integration(user, "outlook", "https://graph.microsoft.com/Calendars.ReadWrite")

      # Outlook caches each occurrence under an iCalendar UID of its own.
      row = fn uid, start_at ->
        series_row(integration, video, uid, "master-1", start_at, %{
          provider_calendar_id: "primary",
          provider_metadata: %{"type" => "occurrence"}
        })
      end

      %{
        integration: integration,
        first: row.("040000008200E00074C5B7101A82E008-first", ~U[2026-06-01 07:00:00Z]),
        occurrence: row.("040000008200E00074C5B7101A82E008-november", ~U[2026-11-02 08:00:00Z])
      }
    end

    defp outlook do
      fn
        :get, url ->
          if String.contains?(url, "/master-1/calendar"),
            do: {200, %{"id" => "team-calendar"}},
            else: {200, @outlook_master}

        :post, _url ->
          {201, %{"id" => "tail-1", "iCalUId" => "040000008200E00074C5B7101A82E009"}}

        :patch, _url ->
          {200, @outlook_master}

        :delete, _url ->
          {204, nil}
      end
    end

    test "a split keeps the video on both halves; the following colours have nowhere to go", %{
      user: user,
      video: video,
      integration: integration,
      first: first,
      occurrence: occurrence
    } do
      colour(user, integration, first.uid, "sage")
      colour(user, integration, occurrence.uid, "grape")
      serve(outlook())

      assert {:ok, _updated} =
               CalendarGrid.update_event(user.id, occurrence, %{summary: "Standup"},
                 recurrence_scope: :following
               )

      assert colours(user) == %{{:external, integration.id, first.uid} => "sage"}

      head = synced_row(integration, first.uid, "master-1", ~U[2026-06-01 07:00:00Z])

      tail =
        synced_row(
          integration,
          "040000008200E00074C5B7101A82E009-november",
          "tail-1",
          ~U[2026-11-02 08:00:00Z]
        )

      assert [:ok, :ok] = run_video_jobs()
      assert video_of(integration, head.uid) == {video.id, @link}
      assert video_of(integration, tail.uid) == {video.id, @link}
    end

    # Teams on the calendar's own Microsoft account would attach its meeting
    # to the event, which a moved copy does not keep; a meeting recorded as
    # a Teams event of its own does travel, and so does its link.
    test "a move to another account's calendar takes the video of a separate Teams event", %{
      user: user
    } do
      source =
        insert(:calendar_integration,
          user: user,
          provider: "outlook",
          provider_account_id: "microsoft-account-1"
        )

      teams =
        insert(:video_integration,
          user: user,
          provider: "teams",
          provider_account_id: "microsoft-account-1"
        )

      teams_link = "https://teams.microsoft.com/l/meetup-join/weekly-sync"

      occurrence =
        series_row(
          source,
          teams,
          "040000008200E00074C5B7101A82E008-november",
          "master-1",
          ~U[2026-11-02 08:00:00Z],
          %{
            provider_calendar_id: "primary",
            provider_metadata: %{"type" => "occurrence"},
            description: "Join video call: #{teams_link}",
            video_link: teams_link
          }
        )

      {:ok, _room} =
        EventVideoRoomQueries.insert(%{
          user_id: user.id,
          video_integration_id: teams.id,
          provider: "teams",
          calendar_integration_id: source.id,
          event_uid: "040000008200E00074C5B7101A82E008",
          provider_event_id: "master-1",
          provider_calendar_id: "primary",
          room_id: "AAMk-separate-teams-event",
          lobby_opens_at: ~U[2026-06-01 06:45:00Z],
          ends_at: nil
        })

      destination =
        insert(:calendar_integration,
          user: user,
          provider: "outlook",
          provider_account_id: "microsoft-account-2"
        )

      written = %{
        uid: "040000008200E00074C5B7101A82E009",
        id: "copy-1",
        calendar_id: "projects",
        source: :removed
      }

      assert {:ok, _moved} =
               SeriesTransfer.move(user.id, occurrence, %{integration: destination},
                 writer: fn :outlook, _transfer -> {:ok, written} end
               )

      moved =
        synced_row(
          destination,
          "040000008200E00074C5B7101A82E009-november",
          "copy-1",
          ~U[2026-11-02 08:00:00Z]
        )

      assert [:ok] = run_video_jobs()
      assert video_of(destination, moved.uid) == {teams.id, teams_link}
    end
  end
end
