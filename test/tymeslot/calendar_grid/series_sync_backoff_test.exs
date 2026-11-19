defmodule Tymeslot.CalendarGrid.SeriesSyncBackoffTest do
  @moduledoc """
  A repeating event made in the calendar, or an event given a repeat rule
  there, asks for a sync at once to bring its occurrences. The series is
  previewed from its row meanwhile, so nothing is missing while a sync waits
  out an error's backoff, and the write leaves that sync to it rather than
  asking a failing provider again.
  """
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :integration

  alias Tymeslot.CalendarGrid.Changes
  alias Tymeslot.Integrations.Calendar.DebugStore
  alias Tymeslot.Integrations.Calendar.Runtime.Operations
  alias Tymeslot.Workers.SyncDebugCalendarWorker

  @rule "FREQ=WEEKLY;COUNT=4"

  setup do
    previous_module = Application.get_env(:tymeslot, :calendar_module)
    Application.put_env(:tymeslot, :calendar_module, Operations)

    on_exit(fn ->
      if previous_module,
        do: Application.put_env(:tymeslot, :calendar_module, previous_module),
        else: Application.delete_env(:tymeslot, :calendar_module)
    end)

    start_supervised!(DebugStore)
    DebugStore.set_pattern(:empty)

    user = insert(:user)
    integration = insert(:calendar_integration, user: user, provider: "debug", is_active: true)

    {:ok, job} =
      %{"calendar_integration_id" => integration.id}
      |> SyncDebugCalendarWorker.new()
      |> Oban.insert()

    backoff_until = DateTime.add(DateTime.utc_now(), 240, :second)

    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
      set: [state: "retryable", scheduled_at: backoff_until, attempt: 1]
    )

    first_start =
      DateTime.utc_now()
      |> DateTime.to_date()
      |> Date.add(1)
      |> DateTime.new!(~T[18:00:00.000000], "Etc/UTC")

    %{
      user: user,
      integration: integration,
      job: job,
      backoff_until: backoff_until,
      first_start: first_start
    }
  end

  test "a series created repeating leaves the sync to its backoff", ctx do
    {:ok, _created} =
      Changes.create_event(ctx.user.id, payload(ctx.integration, ctx.first_start, @rule))

    assert Repo.get!(Oban.Job, ctx.job.id).scheduled_at == ctx.backoff_until
  end

  test "an event given a repeat rule leaves the sync to its backoff", ctx do
    {:ok, %{event: one_off}} =
      Changes.create_event(ctx.user.id, payload(ctx.integration, ctx.first_start, nil))

    {:ok, _updated} =
      Changes.update_event(ctx.user.id, one_off, %{recurrence_rule: @rule}, timezone: "Etc/UTC")

    assert Repo.get!(Oban.Job, ctx.job.id).scheduled_at == ctx.backoff_until
  end

  defp payload(integration, start_at, rule) do
    %{
      creating: %{
        title: "Weekly review",
        integration_id: integration.id,
        attendees: [],
        recurrence_rule: rule
      },
      start_at: start_at,
      end_at: DateTime.add(start_at, 3600),
      timezone: "Etc/UTC"
    }
  end
end
