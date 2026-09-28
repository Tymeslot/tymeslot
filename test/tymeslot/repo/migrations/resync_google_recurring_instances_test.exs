defmodule Tymeslot.Repo.Migrations.ResyncGoogleRecurringInstancesTest do
  @moduledoc """
  The migration clears the collapsed cache rows of Google recurring series
  for a bootstrap to rebuild, but a sync never writes a row's video. A series
  the grid created with a video recorded that video on the one row it cached
  (its master, or the collapsed row the sync later made of it), so what
  matters is that after the migration and the bootstrap that follows, the
  series' occurrences carry that video.

  The API client is mocked at its behaviour; the migration and everything
  from the sync worker down to the cache are real.
  """
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :migrations

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Test.MigrationRunner
  alias Tymeslot.Workers.SyncGoogleCalendarWorker

  setup :verify_on_exit!

  @version 20_260_925_083_349

  @grid_link "https://video.example.com/join/grid-created"
  @collapsed_link "https://video.example.com/join/collapsed"

  setup do
    user = insert(:user)

    integration =
      insert(:calendar_integration,
        user: user,
        provider: "google",
        google_sync_token: "token-before-the-upgrade",
        default_booking_calendar_id: nil,
        calendar_list: []
      )

    base =
      DateTime.utc_now()
      |> DateTime.add(3, :day)
      |> Map.merge(%{hour: 9, minute: 0, second: 0, microsecond: {0, 6}})

    %{
      integration: integration,
      video: insert(:video_integration, user: user, provider: "mirotalk"),
      base: base
    }
  end

  defp stamp(datetime), do: Calendar.strftime(datetime, "%Y%m%dT%H%M%SZ")

  defp row(integration, attrs) do
    insert(
      :provider_calendar_event,
      Keyword.merge(
        [calendar_integration: integration, provider: "google", provider_calendar_id: "primary"],
        attrs
      )
    )
  end

  defp instance(master, start_at) do
    %{
      "id" => "#{master}_#{stamp(start_at)}",
      "iCalUID" => "#{master}@google.com",
      "recurringEventId" => master,
      "originalStartTime" => %{"dateTime" => DateTime.to_iso8601(start_at)},
      "status" => "confirmed",
      "summary" => "Weekly",
      "start" => %{"dateTime" => DateTime.to_iso8601(start_at)},
      "end" => %{"dateTime" => DateTime.to_iso8601(DateTime.add(start_at, 1800, :second))}
    }
  end

  defp video_of(integration, uid) do
    {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, uid)
    {row.video_integration_id, row.video_link}
  end

  defp cached?(integration, uid),
    do: match?({:ok, _row}, ProviderCalendarEventQueries.get_by_uid(integration.id, uid))

  test "the occurrences the bootstrap brings back carry the video their series' row held",
       %{integration: integration, video: video, base: base} do
    # A series the grid created with a video, cached as its master.
    row(integration,
      uid: "grid@google.com",
      provider_event_id: "grid",
      recurrence_rule: "FREQ=WEEKLY",
      start_at: base,
      end_at: DateTime.add(base, 1800, :second),
      video_link: @grid_link,
      video_integration_id: video.id
    )

    # One the sync collapsed into a single instance row, which kept the video
    # the grid's master row held under the same iCalUID.
    row(integration,
      uid: "collapsed@google.com",
      provider_event_id: "collapsed_#{stamp(base)}",
      recurring_event_id: "collapsed",
      start_at: base,
      end_at: DateTime.add(base, 1800, :second),
      video_link: @collapsed_link,
      video_integration_id: video.id
    )

    # A collapsed series with no video, and a single event.
    row(integration,
      uid: "plain@google.com",
      provider_event_id: "plain_#{stamp(base)}",
      recurring_event_id: "plain",
      start_at: base,
      end_at: DateTime.add(base, 1800, :second)
    )

    row(integration,
      uid: "single@google.com",
      provider_event_id: "single",
      start_at: base,
      end_at: DateTime.add(base, 1800, :second)
    )

    MigrationRunner.replay!(@version)

    refute cached?(integration, "plain@google.com")
    assert cached?(integration, "single@google.com")
    assert {:ok, %{google_sync_token: nil}} = CalendarIntegrationQueries.get(integration.id)

    # The collapsed row now stands for its series' master until the sync
    # replaces it.
    assert {:ok, %{provider_event_id: "collapsed", recurring_event_id: nil}} =
             ProviderCalendarEventQueries.get_by_uid(integration.id, "collapsed@google.com")

    next_week = DateTime.add(base, 7, :day)
    starts = [base, next_week]

    expect(GoogleCalendarAPIMock, :list_events_incremental, fn _integration ->
      {:error, :no_sync_token}
    end)

    expect(GoogleCalendarAPIMock, :bootstrap_sync, fn _integration ->
      events =
        for master <- ["grid", "collapsed", "plain"], start <- starts, do: instance(master, start)

      {:ok, %{events: events, next_sync_token: "fresh"}}
    end)

    assert :ok =
             perform_job(SyncGoogleCalendarWorker, %{"calendar_integration_id" => integration.id})

    for start <- starts do
      assert video_of(integration, "grid@google.com_#{stamp(start)}") == {video.id, @grid_link}

      assert video_of(integration, "collapsed@google.com_#{stamp(start)}") ==
               {video.id, @collapsed_link}

      assert video_of(integration, "plain@google.com_#{stamp(start)}") == {nil, nil}
    end

    # Replaced by their occurrences, not shown beside them.
    refute cached?(integration, "grid@google.com")
    refute cached?(integration, "collapsed@google.com")
  end
end
