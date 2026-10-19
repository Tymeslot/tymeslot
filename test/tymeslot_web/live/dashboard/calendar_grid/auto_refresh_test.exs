defmodule TymeslotWeb.Dashboard.CalendarGrid.AutoRefreshTest do
  @moduledoc """
  The sync the calendar grid asks for by itself when it opens on stale
  events. It brings an idle calendar up to date, but leaves a calendar whose
  sync is waiting out an error's backoff to that backoff: opening the grid
  again and again must not keep calling a provider that is failing.
  """
  use TymeslotWeb.LiveCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :live

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Repo
  alias Tymeslot.Workers.SyncExchangeCalendarWorker
  alias Tymeslot.Workers.SyncIcsCalendarWorker

  setup :setup_dashboard_user

  test "opening a stale grid syncs an idle calendar but not one backing off", %{
    conn: conn,
    user: user
  } do
    failing =
      insert(:calendar_integration,
        user: user,
        is_active: true,
        provider: "exchange",
        last_external_sync_at: nil
      )

    idle =
      insert(:calendar_integration,
        user: user,
        is_active: true,
        provider: "ics_url",
        last_external_sync_at: nil
      )

    {:ok, job} =
      %{"calendar_integration_id" => failing.id}
      |> SyncExchangeCalendarWorker.new()
      |> Oban.insert()

    backoff_until = DateTime.add(DateTime.utc_now(), 240, :second)

    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
      set: [state: "retryable", scheduled_at: backoff_until, attempt: 1]
    )

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    _html = render(lv)

    assert_enqueued(
      worker: SyncIcsCalendarWorker,
      args: %{"calendar_integration_id" => idle.id}
    )

    assert %{state: "retryable", scheduled_at: ^backoff_until} = Repo.get!(Oban.Job, job.id)
  end
end
