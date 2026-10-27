defmodule Tymeslot.Infrastructure.FinchPool.Janitor do
  @moduledoc """
  Starts the tagged pools `FinchPool` serves pinned requests from, and stops
  them again once nothing has used them for a while.

  Every pinned request (one SSRF-guarded call to a webhook, CalDAV server,
  calendar feed or self-hosted video server) gets a pool tagged by its
  destination's resolved address and connection options. Destinations are
  user-supplied and DNS moves, so without this a long-running node kept one
  idle pool for every destination it had ever contacted.

  Stopping a pool is safe only if no request is about to use it. A request
  that found its pool alive and then had it stopped would reach Finch with
  no pool under its tag, and Finch starts one itself, with the instance's
  default configuration: without the pinned hostname, so every HTTPS request
  to that destination fails certificate verification for as long as the node
  runs. So a request takes a *lease* first, and the lease is granted in the
  same process, and so in the same order, as pools are started and stopped:

    * `lease/4` starts the pool if needed and records the lease, in one call;
    * the sweep stops only pools with no lease, idle past `:idle_after`, and
      waits for Finch to forget each before handling anything else;
    * a lease ends with `release/2`, or when its holder exits (monitored), so
      a crashed request cannot keep its pool forever.

  A pool Finch has not finished forgetting within `@unregister_timeout` is
  *draining*: a lease on it is refused, so its request goes without a pool,
  until a later lease or sweep finds it gone. A restarted janitor adopts the
  tagged pools its predecessor left on the instance, so they are stopped once
  idle rather than kept until something leases them again. An adopted pool
  is kept for `:adoption_grace` first, since a request its predecessor leased
  it to may still be using it and its lease died with that janitor.
  """

  use GenServer

  alias Finch.Pool
  alias Tymeslot.Infrastructure.Logging.LogFormat
  require Logger

  @finch Tymeslot.Finch
  @default_idle_after :timer.minutes(5)
  # Longer than any request the HTTP client sends: its longest default
  # budget is a CalDAV REPORT's 60 s receive timeout plus the pool and
  # connect waits, and the timeouts integrations configure are in seconds.
  # The client sets no hard ceiling, so this is a margin, not a derived bound.
  @default_adoption_grace :timer.minutes(10)
  @default_sweep_every :timer.minutes(1)
  @lease_timeout :timer.seconds(5)
  # How long a sweep waits for Finch's registries to forget a stopped pool.
  @unregister_timeout 1_000
  # How many draining pools one sweep stops again. Each stop can hold the
  # janitor for `@unregister_timeout`, and leases wait behind the sweep.
  @max_restops_per_sweep 2

  defmodule State do
    @moduledoc false
    @type pool_entry :: %{
            optional(:keep_until) => integer(),
            required(:leases) => MapSet.t(reference()),
            required(:last_used) => integer()
          }
    @type t :: %__MODULE__{
            pools: %{Finch.Pool.t() => pool_entry()},
            leases: %{reference() => {Finch.Pool.t(), reference()}},
            draining: MapSet.t(Finch.Pool.t()),
            idle_after: non_neg_integer(),
            sweep_every: pos_integer() | :manual
          }
    defstruct pools: %{},
              leases: %{},
              draining: MapSet.new(),
              idle_after: 0,
              sweep_every: :manual
  end

  @doc """
  Options: `:idle_after` (ms a pool may sit unused before it is stopped,
  default five minutes), `:sweep_every` (ms between sweeps, default one
  minute, or `:manual` to sweep only through `sweep/1`), `:adopt` (whether
  to take over the tagged pools already on the instance, default true) and
  `:adoption_grace` (ms an adopted pool is kept before it may be stopped,
  default ten minutes).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Whether the janitor is running, and so whether leases can be taken."
  @spec running?(GenServer.server()) :: boolean()
  def running?(server \\ __MODULE__), do: GenServer.whereis(server) != nil

  @doc """
  Ensures a pool tagged `tag` for `url` exists with `pool_options`, and
  leases it to the calling process until `release/2` or the caller's exit.

  `:error` when the pool cannot be started, is still draining, or the
  janitor does not answer (down, restarting, or busy past `timeout`); the
  caller should then go without a pool rather than fail the request.
  """
  @spec lease(String.t(), keyword(), String.t(), GenServer.server(), timeout()) ::
          {:ok, reference()} | :error
  def lease(url, pool_options, tag, server \\ __MODULE__, timeout \\ @lease_timeout) do
    # The caller names the lease, so that it can end one it never heard
    # granted: a call that timed out is still queued, and the janitor would
    # otherwise hold that lease, and its pool, for the caller's lifetime.
    lease = make_ref()

    case call_lease(server, {:lease, lease, url, pool_options, tag}, timeout) do
      :ok ->
        {:ok, lease}

      :error ->
        :error

      {:exit, reason} ->
        release(lease, server)
        Logger.warning("Finch pool lease unavailable", reason: LogFormat.reason(reason))
        :error
    end
  end

  defp call_lease(server, request, timeout) do
    GenServer.call(server, request, timeout)
  catch
    :exit, reason -> {:exit, reason}
  end

  @doc """
  Ends a lease taken with `lease/4`.

  A cast, so ending a lease can never fail the request that held it; a lease
  the janitor never hears about ends with its holder's exit.
  """
  @spec release(reference(), GenServer.server()) :: :ok
  def release(lease, server \\ __MODULE__), do: GenServer.cast(server, {:release, lease})

  @doc "Stops every pool idle past the threshold now; returns how many it stopped."
  @spec sweep(GenServer.server()) :: non_neg_integer()
  def sweep(server \\ __MODULE__), do: GenServer.call(server, :sweep)

  @impl GenServer
  def init(opts) do
    state = %State{
      pools: adopted_pools(opts),
      idle_after: Keyword.get(opts, :idle_after, @default_idle_after),
      sweep_every: Keyword.get(opts, :sweep_every, @default_sweep_every)
    }

    schedule_sweep(state)
    {:ok, state}
  end

  @impl GenServer
  def handle_call({:lease, lease, url, pool_options, tag}, {holder, _tag}, state) do
    with {:ok, pool} <- pool_for(url, tag),
         {:ok, state} <- drained(state, pool),
         :ok <- start_pool(pool, pool_options) do
      {:reply, :ok, grant(state, pool, lease, holder)}
    else
      :draining ->
        {:reply, :error, state}

      {:error, reason} ->
        Logger.warning("Finch pool could not be started", reason: LogFormat.reason(reason))
        {:reply, :error, state}
    end
  end

  def handle_call(:sweep, _from, state) do
    {stopped, state} = stop_idle(state)
    {:reply, stopped, state}
  end

  @impl GenServer
  def handle_cast({:release, lease}, state) do
    case Map.get(state.leases, lease) do
      {_pool, monitor} -> Process.demonitor(monitor, [:flush])
      nil -> :ok
    end

    {:noreply, end_lease(state, lease)}
  end

  @impl GenServer
  def handle_info({{:holder_down, lease}, _monitor, :process, _holder, _reason}, state),
    do: {:noreply, end_lease(state, lease)}

  def handle_info(:sweep, state) do
    {_stopped, state} = stop_idle(state)
    schedule_sweep(state)
    {:noreply, state}
  end

  # Finch keys a pool by scheme, host, port and tag, and a pinned URL names
  # the resolved address, so one tag can cover several pools (a hostname
  # whose DNS rotates). Each is tracked, and stopped, on its own. A URL Finch
  # cannot pool (no scheme, or one other than http and https) raises.
  defp pool_for(url, tag) do
    {:ok, Pool.new(url, tag: tag)}
  rescue
    exception -> {:error, exception}
  end

  # A draining pool can be leased again once Finch has forgotten it.
  defp drained(state, pool) do
    cond do
      not MapSet.member?(state.draining, pool) -> {:ok, state}
      unregistered?(pool) -> {:ok, %{state | draining: MapSet.delete(state.draining, pool)}}
      true -> :draining
    end
  end

  # The holder's monitor carries the lease, so a holder that exits releases
  # it through its :DOWN message.
  defp grant(state, pool, lease, holder) do
    monitor = :erlang.monitor(:process, holder, tag: {:holder_down, lease})

    entry =
      state.pools
      |> Map.get(pool, %{leases: MapSet.new(), last_used: now()})
      |> Map.update!(:leases, &MapSet.put(&1, lease))

    %{
      state
      | pools: Map.put(state.pools, pool, entry),
        leases: Map.put(state.leases, lease, {pool, monitor})
    }
  end

  # Finch raises on invalid options and on an instance that is not running,
  # and exits when its pool supervisor does: none of that may take the
  # janitor, and every lease it holds, down with it. (A start error other
  # than already started surfaces as a CaseClauseError from inside Finch.)
  defp start_pool(pool, pool_options) do
    Finch.start_pool(@finch, pool, pool_options)
  rescue
    exception -> {:error, exception}
  catch
    :exit, reason -> {:error, reason}
  end

  defp end_lease(state, lease) do
    case Map.pop(state.leases, lease) do
      {nil, _leases} ->
        state

      {{pool, _monitor}, leases} ->
        pools =
          Map.update!(state.pools, pool, fn entry ->
            %{entry | leases: MapSet.delete(entry.leases, lease), last_used: now()}
          end)

        %{state | pools: pools, leases: leases}
    end
  end

  # An adopted pool is kept through its grace period. (Monotonic time can be
  # negative, so an entry without one is compared with nothing.)
  defp kept?(%{keep_until: keep_until}), do: now() < keep_until
  defp kept?(_entry), do: false

  defp stop_idle(state) do
    cutoff = now() - state.idle_after

    {idle, in_use} =
      Enum.split_with(state.pools, fn {_pool, entry} ->
        MapSet.size(entry.leases) == 0 and entry.last_used <= cutoff and not kept?(entry)
      end)

    stuck = for {pool, _entry} <- idle, stop_pool(pool) == :draining, do: pool
    draining = state.draining |> still_draining() |> MapSet.union(MapSet.new(stuck))

    {length(idle), %{state | pools: Map.new(in_use), draining: draining}}
  end

  # A draining pool Finch still finds is stopped again, since its last stop
  # may have exited before it took; no lease can hold one, so that is safe.
  # A few per sweep, so pools that never unregister cannot hold the janitor
  # past a lease's timeout. One Finch no longer finds only waits for its
  # registries to catch up, and is dropped once they have.
  defp still_draining(draining) do
    {found, not_found} =
      Enum.split_with(draining, &match?({:ok, _pid}, Finch.find_pool(@finch, &1)))

    {restop, later} = Enum.split(found, @max_restops_per_sweep)

    MapSet.new(
      Enum.reject(not_found, &unregistered?/1) ++
        Enum.filter(restop, &(stop_pool(&1) == :draining)) ++ later
    )
  end

  # A pool already gone (its supervisor restarted, say) needs no stopping.
  # One whose stop exits, or that Finch has not forgotten in time, is left
  # draining.
  defp stop_pool(pool) do
    case Finch.stop_pool(@finch, pool) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end

    await_unregistered(pool, System.monotonic_time(:millisecond) + @unregister_timeout)
  catch
    :exit, _reason -> :draining
  end

  # Finch's registries drop a stopped pool's entries only once they process
  # its exit, and until then a lookup returns the dead pids: a lease taken
  # in that window would skip starting the pool, and its request would reach
  # a dead one. So the janitor handles no lease until both have caught up.
  defp await_unregistered(pool, deadline) do
    cond do
      unregistered?(pool) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        # The tag is a digest of the pool's options, proxy credentials
        # included, so it is not logged.
        Logger.warning("Stopped Finch pool still registered", host: pool.host)
        :draining

      true ->
        Process.sleep(1)
        await_unregistered(pool, deadline)
    end
  end

  defp unregistered?(pool) do
    Finch.find_pool(@finch, pool) == :error and
      Finch.get_pool_count(@finch, pool) == {:error, :not_found}
  catch
    # The pool supervisor's entry outlived its process.
    :exit, _reason -> false
  end

  defp adopted_pools(opts) do
    if Keyword.get(opts, :adopt, true),
      do: adopt_pools(now() + Keyword.get(opts, :adoption_grace, @default_adoption_grace)),
      else: %{}
  end

  # Only pinned pools carry a binary tag; the instance's default pool is
  # tagged `:default`. Each is kept until `keep_until`, so a request a
  # previous janitor leased one to can finish on it.

  defp adopt_pools(keep_until) do
    # Finch has no public listing of its pools, so this reads the registry
    # it keys them in.
    @finch
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.uniq()
    |> Enum.filter(&match?({_scheme, _host, _port, tag} when is_binary(tag), &1))
    |> Map.new(fn {scheme, host, port, tag} ->
      {%Pool{scheme: scheme, host: host, port: port, tag: tag},
       %{leases: MapSet.new(), last_used: now(), keep_until: keep_until}}
    end)
  rescue
    # No Finch instance running: nothing to adopt.
    exception in ArgumentError ->
      Logger.warning("Finch pools could not be adopted", reason: LogFormat.reason(exception))
      %{}
  end

  defp schedule_sweep(%State{sweep_every: :manual}), do: :ok
  defp schedule_sweep(%State{sweep_every: every}), do: Process.send_after(self(), :sweep, every)

  defp now, do: System.monotonic_time(:millisecond)
end
