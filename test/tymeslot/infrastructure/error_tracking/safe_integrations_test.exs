defmodule Tymeslot.Infrastructure.ErrorTracking.SafeIntegrationsTest do
  # async: false: ErrorTracker's configuration and the telemetry handlers are
  # global.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :infrastructure
  @moduletag :integration

  import Tymeslot.ConfigTestHelpers

  alias ErrorTracker.Error
  alias ExUnit.CaptureLog
  alias Tymeslot.Infrastructure.ErrorTracking.SafeIntegrations
  alias Tymeslot.Repo

  # Stands in for the application repo while the database is unreachable, as
  # during pool exhaustion: every query ErrorTracker makes raises.
  defmodule UnreachableRepo do
    @moduledoc false

    @spec __adapter__() :: module()
    def __adapter__, do: Ecto.Adapters.Postgres

    # A report's first query, so the only one that needs to fail.
    @spec one(Ecto.Queryable.t(), keyword()) :: no_return()
    def one(_queryable, _opts),
      do: raise(DBConnection.ConnectionError, "connection not available")
  end

  defmodule RaisingWorker do
    @moduledoc false
    use Oban.Worker, queue: :default, max_attempts: 3

    @impl Oban.Worker
    def perform(%Oban.Job{}), do: raise("job exploded")
  end

  @stacktrace [{Tymeslot.Bookings, :create_booking, 2, [file: ~c"lib/bookings.ex", line: 42]}]

  setup do
    with_config(:error_tracker, enabled: true)
    on_exit(&SafeIntegrations.install/0)
    :ok
  end

  defp database_down(fun) do
    with_config(:error_tracker, repo: UnreachableRepo)
    CaptureLog.capture_log(fun)
    with_config(:error_tracker, repo: Repo)
    # The context the next event's `:start` handler sets must come from that
    # handler, not from what the failed attempt left behind.
    Process.delete(:error_tracker_context)
  end

  defp live_view_exception do
    # Complete enough for LiveView's own logger, attached to the same event.
    :telemetry.execute([:phoenix, :live_view, :mount, :start], %{system_time: 0}, %{
      socket: %Phoenix.LiveView.Socket{view: TymeslotWeb.DashboardLive},
      params: %{},
      session: %{},
      uri: "http://localhost/dashboard"
    })

    :telemetry.execute([:phoenix, :live_view, :handle_event, :exception], %{}, %{
      kind: :error,
      reason: %RuntimeError{message: "save exploded"},
      stacktrace: @stacktrace,
      event: "save",
      params: %{}
    })
  end

  describe "a report that fails while the database is unreachable" do
    test "leaves the LiveView integration recording later exceptions with their context" do
      database_down(&live_view_exception/0)
      assert Repo.all(Error) == []

      live_view_exception()

      assert [%Error{reason: "save exploded"} = error] =
               Repo.preload(Repo.all(Error), :occurrences)

      assert [%{context: context}] = error.occurrences
      assert context["live_view.view"] == "Elixir.TymeslotWeb.DashboardLive"
    end

    test "leaves the Oban integration recording later job failures with their context" do
      database_down(fn ->
        assert_raise RuntimeError, fn -> perform_job(RaisingWorker, %{}) end
      end)

      assert Repo.all(Error) == []

      assert_raise RuntimeError, fn -> perform_job(RaisingWorker, %{}) end

      assert [%Error{reason: "job exploded"} = error] =
               Repo.preload(Repo.all(Error), :occurrences)

      assert [%{context: context}] = error.occurrences
      assert context["job.worker"] == inspect(RaisingWorker)
    end
  end

  # The handler ids and events are copied from error_tracker's integrations.
  # An upgrade that renames either must fail here, not leave the library's
  # unguarded handlers attached beside these.
  describe "install/0" do
    test "names exactly the handlers and events ErrorTracker's integrations attach" do
      for {integration, events} <- SafeIntegrations.integrations() do
        _detached = :telemetry.detach(integration)
        :ok = integration.attach()

        attached =
          []
          |> :telemetry.list_handlers()
          |> Enum.filter(&(&1.id == integration))
          |> Enum.map(& &1.event_name)

        assert Enum.sort(attached) == Enum.sort(events)
      end
    end

    test "replaces the library's handlers with guarded ones" do
      Enum.each(SafeIntegrations.integrations(), fn {integration, _events} ->
        integration.attach()
      end)

      SafeIntegrations.install()

      guarded = Function.capture(SafeIntegrations, :handle_event, 4)
      handlers = :telemetry.list_handlers([])

      for {integration, events} <- SafeIntegrations.integrations() do
        refute Enum.any?(handlers, &(&1.id == integration))

        assert Enum.reject(events, fn event ->
                 Enum.any?(handlers, &(&1.event_name == event and &1.function == guarded))
               end) == []
      end
    end
  end
end
