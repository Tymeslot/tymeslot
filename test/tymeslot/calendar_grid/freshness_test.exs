defmodule Tymeslot.CalendarGrid.FreshnessTest do
  @moduledoc """
  The refresh the calendar grid starts by itself when it opens on stale
  events, against the owner's own Refresh: the first leaves a sync waiting
  out an error's backoff to it, the second brings it forward.
  """
  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar

  import Tymeslot.Factory

  alias Tymeslot.CalendarGrid.Freshness
  alias Tymeslot.Workers.SyncExchangeCalendarWorker
  alias Tymeslot.Workers.SyncGoogleCalendarWorker

  setup do
    user = insert(:user)
    failing = insert(:calendar_integration, user: user, provider: "exchange")
    idle = insert(:calendar_integration, user: user, provider: "google")

    {:ok, job} =
      %{"calendar_integration_id" => failing.id}
      |> SyncExchangeCalendarWorker.new()
      |> Oban.insert()

    backoff_until = DateTime.add(DateTime.utc_now(), 240, :second)

    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
      set: [state: "retryable", scheduled_at: backoff_until, attempt: 1]
    )

    %{user: user, idle: idle, job: job, backoff_until: backoff_until}
  end

  test "an opened grid leaves a retrying sync to its backoff and counts it as skipped", ctx do
    assert {:ok, %{enqueued: 1, skipped: 1, errors: []}} =
             Freshness.refresh_events(ctx.user.id, :opened)

    assert Repo.get!(Oban.Job, ctx.job.id).scheduled_at == ctx.backoff_until

    assert_enqueued(
      worker: SyncGoogleCalendarWorker,
      args: %{"calendar_integration_id" => ctx.idle.id}
    )
  end

  test "the owner's Refresh brings a retrying sync forward", ctx do
    assert {:ok, %{enqueued: 2, skipped: 0, errors: []}} = Freshness.refresh_events(ctx.user.id)

    %{scheduled_at: scheduled_at} = Repo.get!(Oban.Job, ctx.job.id)
    assert DateTime.before?(scheduled_at, DateTime.add(DateTime.utc_now(), 5, :second))
  end
end
