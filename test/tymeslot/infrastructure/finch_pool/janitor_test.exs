defmodule Tymeslot.Infrastructure.FinchPool.JanitorTest do
  @moduledoc """
  The janitor stops the per-destination pools pinned requests leave on
  `Tymeslot.Finch`, and never one a request is about to use: a pool stopped
  under a request is restarted by Finch with the instance's defaults,
  without the pinned hostname, and every HTTPS request to that destination
  then fails certificate verification.

  Each test runs its own janitor (manual sweeps, no idle grace, adopting
  nothing) on the shared Finch instance, over destinations no other test
  uses.
  """

  use ExUnit.Case, async: false

  @moduletag :infrastructure

  alias Finch.Pool
  alias Tymeslot.Infrastructure.FinchPool.Janitor

  @finch Tymeslot.Finch
  # How many times the race test's sweeper must stop the pool under the holders.
  @min_stops 5

  setup do
    name = {:global, {__MODULE__, System.unique_integer([:positive])}}
    start_supervised!({Janitor, name: name, idle_after: 0, sweep_every: :manual, adopt: false})
    %{janitor: name}
  end

  defp destination do
    n = System.unique_integer([:positive])
    {url_for(n, 0), "pool-#{n}", [conn_opts: [hostname: "pinned-#{n}.example.com"]]}
  end

  # A second address for the same destination: the hostname's DNS moved.
  defp url_for(n, shift),
    do: "https://192.0.2.#{rem(n + shift, 250) + 1}:#{10_000 + rem(n, 50_000)}/hook"

  defp lease!(url, options, tag, janitor) do
    {:ok, lease} = Janitor.lease(url, options, tag, janitor)
    lease
  end

  # `release/2` is a cast; a call queued behind it returns once it is handled.
  defp release!(lease, janitor) do
    :ok = Janitor.release(lease, janitor)
    :sys.get_state(janitor)
  end

  defp pool_alive?(url, tag),
    do: match?({:ok, _pid}, Finch.find_pool(@finch, Pool.new(url, tag: tag)))

  defp pinned_hostname(url, tag) do
    {:ok, pid} = Finch.find_pool(@finch, Pool.new(url, tag: tag))
    %{state: %{opts: %{conn_opts: conn_opts}}} = :sys.get_state(pid)
    conn_opts[:hostname]
  end

  # Sweeps until `expected` pools have been stopped in all, or fails.
  defp sweep_until(janitor, expected, stopped \\ 0, deadline \\ deadline()) do
    stopped = stopped + Janitor.sweep(janitor)

    cond do
      stopped >= expected -> stopped
      System.monotonic_time(:millisecond) > deadline -> stopped
      true -> sweep_until(janitor, expected, stopped, deadline)
    end
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 2_000

  defp hold_registry_entry!(pool) do
    test_pid = self()
    {scheme, host, port, tag} = {pool.scheme, pool.host, pool.port, pool.tag}

    holder =
      spawn(fn ->
        {:ok, _owner} = Registry.register(@finch, {scheme, host, port, tag}, Finch.HTTP1.Pool)
        send(test_pid, :registered)
        receive do: (:release -> :ok)
      end)

    assert_receive :registered
    on_exit(fn -> send(holder, :release) end)
  end

  defp start_unleased!(url, tag, options) do
    :ok = Finch.start_pool(@finch, Pool.new(url, tag: tag), options)
  end

  # Finch's registries forget a stopped pool in their own time.
  defp await_lease(url, options, tag, janitor, deadline \\ deadline()) do
    case Janitor.lease(url, options, tag, janitor) do
      {:ok, lease} ->
        lease

      :error ->
        if System.monotonic_time(:millisecond) > deadline,
          do: flunk("the draining pool was never leased again"),
          else: await_lease(url, options, tag, janitor, deadline)
    end
  end

  test "stops a pool once its last lease has ended and it has sat idle", %{janitor: janitor} do
    {url, tag, options} = destination()

    lease = lease!(url, options, tag, janitor)
    assert pool_alive?(url, tag)
    release!(lease, janitor)

    assert Janitor.sweep(janitor) == 1
    # The sweep returns only once Finch has forgotten the pool.
    refute pool_alive?(url, tag)
  end

  test "stops every pool a tag covers, one per address", %{janitor: janitor} do
    {_url, tag, options} = destination()
    n = System.unique_integer([:positive])
    {first, second} = {url_for(n, 0), url_for(n, 1)}

    for url <- [first, second], do: release!(lease!(url, options, tag, janitor), janitor)
    assert pool_alive?(first, tag) and pool_alive?(second, tag)

    assert Janitor.sweep(janitor) == 2
    refute pool_alive?(first, tag)
    refute pool_alive?(second, tag)
  end

  test "keeps a pool while a lease on it is outstanding", %{janitor: janitor} do
    {url, tag, options} = destination()

    lease = lease!(url, options, tag, janitor)
    assert Janitor.sweep(janitor) == 0
    assert pool_alive?(url, tag)

    release!(lease, janitor)
  end

  test "keeps a pool idle for less than the threshold" do
    name = {:global, {__MODULE__, :patient, System.unique_integer([:positive])}}

    start_supervised!(
      {Janitor, name: name, idle_after: :timer.hours(1), sweep_every: :manual, adopt: false},
      id: name
    )

    {url, tag, options} = destination()

    release!(lease!(url, options, tag, name), name)

    assert Janitor.sweep(name) == 0
    assert pool_alive?(url, tag)
  end

  # A request that crashes between taking and returning its lease must not
  # keep the pool forever.
  test "ends the lease of a holder that exits", %{janitor: janitor} do
    {url, tag, options} = destination()
    test_pid = self()

    holder =
      spawn(fn ->
        lease!(url, options, tag, janitor)
        send(test_pid, :leased)
        receive do: (:exit -> :ok)
      end)

    assert_receive :leased
    assert Janitor.sweep(janitor) == 0

    send(holder, :exit)

    # The janitor hears of the exit through its own monitor, in its own time.
    assert sweep_until(janitor, 1) == 1
    refute pool_alive?(url, tag)
  end

  test "a pool that cannot be started refuses the lease and keeps the others",
       %{janitor: janitor} do
    {url, tag, options} = destination()
    held = lease!(url, options, tag, janitor)
    pid = GenServer.whereis(janitor)

    {bad_url, bad_tag, _options} = destination()
    assert Janitor.lease(bad_url, [protocols: [:nope]], bad_tag, janitor) == :error

    # Same process, lease intact: the sweep still leaves the leased pool alone.
    assert GenServer.whereis(janitor) == pid
    assert Janitor.sweep(janitor) == 0
    release!(held, janitor)
    assert Janitor.sweep(janitor) == 1
  end

  test "a URL Finch cannot pool refuses the lease and keeps the janitor", %{janitor: janitor} do
    {url, tag, options} = destination()
    held = lease!(url, options, tag, janitor)
    pid = GenServer.whereis(janitor)

    assert Janitor.lease("ftp://192.0.2.1/hook", options, "bad-scheme", janitor) == :error
    assert Janitor.lease("192.0.2.1/hook", options, "no-scheme", janitor) == :error

    assert GenServer.whereis(janitor) == pid
    assert Janitor.sweep(janitor) == 0
    release!(held, janitor)
  end

  # The caller gave up, so nothing will release the lease it was granted
  # late but the caller itself.
  test "a lease that timed out is ended once the janitor catches up", %{janitor: janitor} do
    {url, tag, options} = destination()
    :ok = :sys.suspend(janitor)

    assert Janitor.lease(url, options, tag, janitor, 50) == :error

    :ok = :sys.resume(janitor)
    assert %{leases: leases} = :sys.get_state(janitor)
    assert leases == %{}
    assert Janitor.sweep(janitor) == 1
    refute pool_alive?(url, tag)
  end

  # A pool Finch has not finished forgetting would hand a lease dead pids.
  test "a draining pool is refused until Finch has forgotten it", %{janitor: janitor} do
    {url, tag, options} = destination()
    pool = Pool.new(url, tag: tag)
    :sys.replace_state(janitor, &%{&1 | draining: MapSet.put(&1.draining, pool)})

    # Still registered: the lease is refused, and no pool is started.
    start_unleased!(url, tag, options)
    assert Janitor.lease(url, options, tag, janitor) == :error

    # Gone: the next lease starts it afresh.
    :ok = Finch.stop_pool(@finch, pool)
    assert lease = await_lease(url, options, tag, janitor)
    assert pool_alive?(url, tag)
    assert %{draining: draining} = :sys.get_state(janitor)
    refute MapSet.member?(draining, pool)
    release!(lease, janitor)
  end

  # Its last stop may have exited before it took.
  test "a draining pool is stopped again on the next sweep", %{janitor: janitor} do
    {url, tag, options} = destination()
    pool = Pool.new(url, tag: tag)
    start_unleased!(url, tag, options)
    :sys.replace_state(janitor, &%{&1 | draining: MapSet.put(&1.draining, pool)})

    Janitor.sweep(janitor)

    refute pool_alive?(url, tag)
    assert %{draining: draining} = :sys.get_state(janitor)
    refute MapSet.member?(draining, pool)
  end

  # A pool whose registry entry outlives every stop: here a process holding
  # the entry Finch looks the pool up by, with no supervisor behind it.
  test "pools that never unregister cannot hold a sweep past a lease's timeout",
       %{janitor: janitor} do
    pools =
      for _n <- 1..5 do
        {url, tag, _options} = destination()
        pool = Pool.new(url, tag: tag)
        hold_registry_entry!(pool)
        pool
      end

    :sys.replace_state(janitor, &%{&1 | draining: MapSet.new(pools)})

    {elapsed_us, 0} = :timer.tc(fn -> Janitor.sweep(janitor) end)

    # At most two are stopped again, each waiting up to a second.
    assert div(elapsed_us, 1_000) < 2_500
    assert %{draining: draining} = :sys.get_state(janitor)
    assert MapSet.equal?(draining, MapSet.new(pools))
  end

  test "a restarted janitor adopts the pools its predecessor left", %{janitor: janitor} do
    {url, tag, options} = destination()
    release!(lease!(url, options, tag, janitor), janitor)
    :ok = stop_supervised(Janitor)
    assert pool_alive?(url, tag)

    name = {:global, {__MODULE__, :adopter, System.unique_integer([:positive])}}

    start_supervised!(
      {Janitor, name: name, idle_after: 0, adoption_grace: 0, sweep_every: :manual},
      id: name
    )

    assert Janitor.sweep(name) >= 1
    refute pool_alive?(url, tag)
  end

  # The predecessor's leases died with it, so a request it leased the pool
  # to may still be using it.
  test "an adopted pool is kept through its grace period", %{janitor: janitor} do
    {url, tag, options} = destination()
    release!(lease!(url, options, tag, janitor), janitor)
    :ok = stop_supervised(Janitor)

    name = {:global, {__MODULE__, :adopter, System.unique_integer([:positive])}}

    start_supervised!(
      {Janitor, name: name, idle_after: 0, adoption_grace: :timer.hours(1), sweep_every: :manual},
      id: name
    )

    pool = Pool.new(url, tag: tag)
    assert Janitor.sweep(name) == 0
    assert pool_alive?(url, tag)
    assert %{pools: %{^pool => _entry}} = :sys.get_state(name)
  end

  test "a janitor that is not running refuses leases without failing the caller" do
    absent = {:global, {__MODULE__, :absent, System.unique_integer([:positive])}}
    {url, tag, options} = destination()

    assert Janitor.lease(url, options, tag, absent) == :error
    assert Janitor.release(make_ref(), absent) == :ok
  end

  # The Trap in the ticket: a sweep deciding to stop a pool while a request is
  # about to use it. Leasing and stopping are serialised in the janitor, so
  # every holder must find its pool alive, and still pinned, for as long as
  # it holds the lease, however the sweeps interleave.
  test "a lease taken while sweeps run never sees its pool stopped", %{janitor: janitor} do
    {url, tag, options} = destination()
    hostname = options[:conn_opts][:hostname]

    # Sweeps for as long as the holders run, counting the pools it stops (1)
    # and the sweeps it has made (2).
    stops = :counters.new(2, [])
    sweeper = Task.async(fn -> sweep_until_stopped(janitor, stops) end)

    observations =
      1..8
      |> Task.async_stream(fn _holder -> hold(url, options, tag, hostname, janitor, stops) end,
        max_concurrency: 8,
        timeout: 30_000
      )
      |> Enum.flat_map(fn {:ok, seen} -> seen end)

    send(sweeper.pid, :stop)
    Task.await(sweeper, 30_000)

    assert length(observations) >= 320
    assert Enum.reject(observations, & &1) == []
    # The sweeps did stop the pool between leases, so the leases raced them.
    assert :counters.get(stops, 1) >= @min_stops
  end

  # Takes and returns leases, recording whether each saw its pool alive and
  # pinned, for at least 40 rounds and until the sweeper has stopped the pool
  # often enough that the leases are known to have raced it. Each holder
  # waits for the next sweep before leasing again, so the pool falls idle
  # between rounds and the next lease lands right behind a sweep.
  defp hold(url, options, tag, hostname, janitor, stops, round \\ 1, seen \\ []) do
    lease = lease!(url, options, tag, janitor)
    ok? = pool_alive?(url, tag) and pinned_hostname(url, tag) == hostname
    sweeps = :counters.get(stops, 2)
    :ok = Janitor.release(lease, janitor)
    await_sweep(stops, sweeps)
    seen = [ok? | seen]

    if round >= 40 and :counters.get(stops, 1) >= @min_stops,
      do: seen,
      else: hold(url, options, tag, hostname, janitor, stops, round + 1, seen)
  end

  defp await_sweep(stops, sweeps) do
    if :counters.get(stops, 2) <= sweeps + 1 do
      :erlang.yield()
      await_sweep(stops, sweeps)
    end
  end

  defp sweep_until_stopped(janitor, stops) do
    receive do
      :stop -> :ok
    after
      0 ->
        :counters.add(stops, 1, Janitor.sweep(janitor))
        :counters.add(stops, 2, 1)
        sweep_until_stopped(janitor, stops)
    end
  end
end
