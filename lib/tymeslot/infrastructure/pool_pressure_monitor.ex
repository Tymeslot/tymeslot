defmodule Tymeslot.Infrastructure.PoolPressureMonitor do
  @moduledoc """
  Raises a `:database_pool_pressure` admin alert when queries keep waiting too
  long for a database connection.

  Every Ecto query event carries `queue_time`: how long the query waited for
  a connection from the pool. A pool that is too small for the load, or held
  by slow queries, shows there long before requests start timing out. This
  monitor counts the queries whose wait exceeds `:threshold_ms` (500 ms by
  default) and, when at least `:limit` of them (20 by default) fall into one
  window of `:window_ms` (a minute by default), raises one alert for that
  window. Each window is counted afresh.

  ## Keeping the query path cheap

  The telemetry handler runs in the process that issued the query, on every
  query. It compares one integer and, only for a slow checkout, increments a
  `:counters` slot; the counters reference and the threshold (in native time
  units) travel in the handler's config, so there is no lookup, no message
  and no lock. This process only reads and resets the counts once per
  window.

  ## Which repos

  `config :tymeslot, :pool_pressure_repos` lists the repos to watch, by
  module; Core defaults it to `[Tymeslot.Repo]` and a deployment with further
  repos extends it. Each repo's query event is read from its own
  `:telemetry_prefix`, so a repo configured with a custom prefix is still
  heard.

  Telemetry detaches a handler that raises, so the handler never does: any
  measurement other than an integer `queue_time` is ignored.
  """

  use GenServer

  require Logger

  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Infrastructure.Logging.LogFormat

  @default_threshold_ms 500
  @default_limit 20
  @default_window_ms :timer.minutes(1)

  @doc """
  Starts the monitor.

  ## Options

    * `:name` - the process name, `#{inspect(__MODULE__)}` by default
    * `:repos` - the repos to watch, `config :tymeslot, :pool_pressure_repos`
      by default
    * `:threshold_ms` - a checkout waiting longer than this is slow
    * `:limit` - the number of slow checkouts in one window that raises an alert
    * `:window_ms` - the window length, or `:manual` to close windows only
      through `evaluate/1`
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @doc """
  Closes the current window now: alerts for any repo over the limit and
  starts counting afresh.
  """
  @spec evaluate(GenServer.server()) :: :ok
  def evaluate(server \\ __MODULE__), do: GenServer.call(server, :evaluate)

  @doc false
  @spec handle_query([atom()], map(), map(), map()) :: :ok
  def handle_query(_event, %{queue_time: queue_time}, _metadata, %{
        counters: counters,
        index: index,
        threshold: threshold
      })
      when is_integer(queue_time) and queue_time > threshold do
    :counters.add(counters, index, 1)
  end

  def handle_query(_event, _measurements, _metadata, _config), do: :ok

  @impl GenServer
  def init(opts) do
    # So that `terminate/2` runs on shutdown and detaches the handlers.
    Process.flag(:trap_exit, true)

    watched =
      opts
      |> Keyword.get_lazy(:repos, fn ->
        Application.get_env(:tymeslot, :pool_pressure_repos, [Tymeslot.Repo])
      end)
      |> Enum.flat_map(&query_event/1)
      |> Enum.with_index(1)

    name = Keyword.fetch!(opts, :name)
    threshold_ms = Keyword.get(opts, :threshold_ms, @default_threshold_ms)
    threshold = System.convert_time_unit(threshold_ms, :millisecond, :native)
    counters = :counters.new(max(length(watched), 1), [:write_concurrency])

    Enum.each(watched, fn {{repo, event}, index} ->
      id = handler_id(name, repo)
      _detached = :telemetry.detach(id)

      :telemetry.attach(id, event, &__MODULE__.handle_query/4, %{
        counters: counters,
        index: index,
        threshold: threshold
      })
    end)

    state = %{
      name: name,
      repos: Enum.map(watched, fn {{repo, _event}, index} -> {repo, index} end),
      counters: counters,
      threshold_ms: threshold_ms,
      limit: Keyword.get(opts, :limit, @default_limit),
      window_ms: Keyword.get(opts, :window_ms, @default_window_ms)
    }

    schedule(state.window_ms)
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:evaluate, _from, state) do
    close_window(state)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info(:evaluate, state) do
    close_window(state)
    schedule(state.window_ms)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    Enum.each(state.repos, fn {repo, _index} ->
      :telemetry.detach(handler_id(state.name, repo))
    end)
  end

  defp close_window(state) do
    Enum.each(state.repos, fn {repo, index} ->
      # Subtract what was read rather than zeroing the slot, so a slow
      # checkout counted between the read and the reset is kept for the next
      # window instead of being lost.
      count = :counters.get(state.counters, index)
      :counters.sub(state.counters, index, count)

      if count >= state.limit, do: alert(repo, count, state)
    end)
  end

  defp alert(repo, count, state) do
    AdminAlerts.report(:database_pool_pressure,
      summary: "Database pool pressure",
      context: %{
        repo: inspect(repo),
        slow_checkouts: count,
        threshold_ms: state.threshold_ms,
        window_seconds: window_seconds(state.window_ms),
        detected_at: DateTime.to_iso8601(DateTime.utc_now())
      }
    )
  end

  defp window_seconds(:manual), do: "manual"
  defp window_seconds(window_ms), do: div(window_ms, 1_000)

  defp schedule(:manual), do: :ok
  defp schedule(window_ms), do: Process.send_after(self(), :evaluate, window_ms)

  defp handler_id(name, repo), do: {__MODULE__, name, repo}

  # A repo whose configuration cannot be read is skipped with a warning
  # rather than taking the monitor, and the application with it, down.
  defp query_event(repo) do
    prefix = Keyword.fetch!(repo.config(), :telemetry_prefix)
    [{repo, prefix ++ [:query]}]
  rescue
    exception ->
      Logger.warning("Pool pressure monitor cannot watch a repo",
        repo: LogFormat.reason(repo),
        error: LogFormat.reason(exception.__struct__)
      )

      []
  end
end
