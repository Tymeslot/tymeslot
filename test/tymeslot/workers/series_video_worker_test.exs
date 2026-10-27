defmodule Tymeslot.Workers.SeriesVideoWorkerTest do
  @moduledoc """
  `Tymeslot.Workers.SeriesVideoWorker` gives a recurring series' cached
  occurrences the series' video once a sync has cached them, and waits for
  that sync, for a while, when it has not.
  """
  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :video
  @moduletag :workers

  import Ecto.Query, only: [where: 2]

  alias Oban.Job
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Workers.SeriesVideoWorker

  @link "https://video.example.com/join/weekly-sync"

  setup do
    user = insert(:user)
    integration = insert(:calendar_integration, user: user, provider: "google")
    video = insert(:video_integration, user: user, provider: "mirotalk")
    %{user: user, integration: integration, video: video}
  end

  defp args(integration, video, master_id \\ "series1") do
    %{
      "calendar_integration_id" => integration.id,
      "address" => ["master", master_id],
      "series_uid" => nil,
      "video_integration_id" => video.id,
      "video_link" => @link
    }
  end

  defp occurrence(integration, uid, attrs \\ %{}) do
    insert(
      :provider_calendar_event,
      Map.merge(
        %{
          calendar_integration: integration,
          provider: "google",
          uid: uid,
          provider_event_id: "series1_#{uid}",
          recurring_event_id: "series1",
          start_at: ~U[2026-06-01 07:00:00Z],
          end_at: ~U[2026-06-01 08:00:00Z],
          all_day: false,
          sync_state: "synced"
        },
        attrs
      )
    )
  end

  defp video_of(row) do
    {:ok, row} = ProviderCalendarEventQueries.get_by_uid(row.calendar_integration_id, row.uid)
    {row.video_integration_id, row.video_link}
  end

  test "gives the series' video to its occurrences that have none, and only to them", %{
    user: user,
    integration: integration,
    video: video
  } do
    plain = occurrence(integration, "a_20260601T070000Z")
    other = insert(:video_integration, user: user, provider: "mirotalk")

    own =
      occurrence(integration, "a_20260608T070000Z", %{
        video_link: "https://video.example.com/join/own",
        video_integration_id: other.id
      })

    elsewhere = occurrence(integration, "b_20260601T070000Z", %{recurring_event_id: "series2"})

    assert :ok = perform_job(SeriesVideoWorker, args(integration, video))

    assert video_of(plain) == {video.id, @link}
    assert video_of(own) == {other.id, "https://video.example.com/join/own"}
    assert video_of(elsewhere) == {nil, nil}
  end

  # The job snoozes for up to two hours, so a second choice of video made
  # minutes after the first must still take over the waiting job rather than
  # start a second one beside it, which could wake first and keep the
  # superseded video.
  test "a later choice of video takes over the waiting job, however old", %{
    user: user,
    integration: integration,
    video: video
  } do
    other_video = insert(:video_integration, user: user, provider: "mirotalk")
    series = %{integration_id: integration.id, address: {:master, "series1"}, uid: nil}

    {:ok, first} = SeriesVideoWorker.enqueue(series, {video.id, @link})

    Repo.update_all(
      where(Job, id: ^first.id),
      set: [inserted_at: DateTime.add(DateTime.utc_now(), -600, :second)]
    )

    {:ok, _second} =
      SeriesVideoWorker.enqueue(series, {other_video.id, "https://video.example.com/b"})

    assert [job] = all_enqueued(worker: SeriesVideoWorker)
    assert job.id == first.id
    assert job.args["video_integration_id"] == other_video.id
  end

  # An `:executing` row whose node stopped stays so until the Lifeline
  # rescues it hours later, and is discarded then if its attempts are spent.
  # A later choice must not fold into it and wait, or be lost, with it.
  describe "a later choice while an orphaned run holds the series" do
    setup %{user: user, integration: integration, video: video} do
      series = %{integration_id: integration.id, address: {:master, "series1"}, uid: nil}
      {:ok, orphaned} = SeriesVideoWorker.enqueue(series, {video.id, @link})
      other_video = insert(:video_integration, user: user, provider: "mirotalk")
      %{series: series, orphaned: orphaned, other_video: other_video}
    end

    defp run_since(job, seconds_ago) do
      Repo.update_all(where(Job, id: ^job.id),
        set: [
          state: "executing",
          attempt: 3,
          attempted_at: DateTime.add(DateTime.utc_now(), -seconds_ago, :second)
        ]
      )
    end

    test "gets a job of its own once the run is past saving", %{
      series: series,
      orphaned: orphaned,
      other_video: other_video
    } do
      run_since(orphaned, 3600)

      {:ok, job} =
        SeriesVideoWorker.enqueue(series, {other_video.id, "https://video.example.com/b"})

      assert job.id != orphaned.id
      assert [waiting] = all_enqueued(worker: SeriesVideoWorker)
      assert waiting.id == job.id
      assert waiting.args["video_integration_id"] == other_video.id
    end

    test "folds into a run still in progress, as before", %{
      series: series,
      orphaned: orphaned,
      other_video: other_video
    } do
      run_since(orphaned, 5)

      {:ok, job} =
        SeriesVideoWorker.enqueue(series, {other_video.id, "https://video.example.com/b"})

      assert job.id == orphaned.id
      assert all_enqueued(worker: SeriesVideoWorker) == []
      assert Repo.get!(Job, orphaned.id).args["video_integration_id"] == other_video.id
    end
  end

  # A write that lands while the job runs folds into that job; the job then
  # runs once more with it instead of finishing without it.
  test "runs again when its args were replaced during the run", %{
    integration: integration,
    video: video
  } do
    occurrence(integration, "a_20260601T070000Z")

    {:ok, job} =
      args(integration, video)
      |> SeriesVideoWorker.new()
      |> Oban.insert()

    Repo.update_all(
      where(Job, id: ^job.id),
      set: [args: Map.put(job.args, "video_link", "https://video.example.com/b")]
    )

    assert {:snooze, _seconds} = SeriesVideoWorker.perform(job)
  end

  test "waits, less often each time, while no occurrence is cached", %{
    integration: integration,
    video: video
  } do
    assert {:snooze, 30} = perform_job(SeriesVideoWorker, args(integration, video))

    assert {:snooze, 120} =
             perform_job(SeriesVideoWorker, args(integration, video), meta: %{"snoozed" => 2})

    assert {:snooze, 600} =
             perform_job(SeriesVideoWorker, args(integration, video), meta: %{"snoozed" => 10})
  end

  test "gives up once the sync has had long enough", %{integration: integration, video: video} do
    assert {:discard, :series_never_cached} =
             perform_job(SeriesVideoWorker, args(integration, video), meta: %{"snoozed" => 16})
  end

  test "writes nothing once the video integration is gone", %{
    integration: integration,
    video: video
  } do
    row = occurrence(integration, "a_20260601T070000Z")
    Repo.delete!(video)

    assert :ok = perform_job(SeriesVideoWorker, args(integration, video))
    assert video_of(row) == {nil, nil}
  end
end
