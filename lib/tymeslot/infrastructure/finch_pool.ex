defmodule Tymeslot.Infrastructure.FinchPool do
  @moduledoc """
  Keeps every outbound request on the application's own Finch instance, even
  when it needs connection options of its own.

  `Tymeslot.Finch` is started once, in `Tymeslot.Application`, with a pool
  configuration a deployment can size for itself. Req will only use a named
  instance when the request carries no `:connect_options`: hand it any, and it
  hashes them into a name, starts *another whole Finch instance* under its own
  supervisor for that name, and keeps it for the lifetime of the node. Since
  the connection pinning that SSRF protection depends on passes the target's
  hostname as a connect option, and that hostname differs per destination, the
  practical effect was one permanent Finch instance, plus one never-collected
  atom, per hostname the application had ever talked to. Webhook destinations
  are user-supplied, so nothing bounded that.

  Those instances also ran on Finch's stock defaults rather than ours, quietly
  dropping the `conn_max_idle_time` that exists to evict connections a remote
  closed behind our back, and the pool size a larger deployment configures.

  Finch can express the same thing without any of that: a *tagged pool* on the
  instance that is already running. `request_option/2` registers one keyed by
  the connection options it needs and returns the Req option that selects it,
  so the caller passes `:finch` alone and never `:connect_options`.
  """

  alias Finch.Pool

  @finch Tymeslot.Finch

  @doc """
  The pool configuration `Tymeslot.Finch` itself starts with.

  `size`/`count` are read from config so a deployment with more headroom can
  run a larger pool than a small self-hosted box; the values below are the
  safe defaults and are overridden via `config :tymeslot, :finch_default_pool`.

  `conn_max_idle_time` (NOT `pool_max_idle_time`) evicts individual
  connections the remote silently closed after its keep-alive timeout,
  preventing "socket closed" errors. `pool_max_idle_time` would instead tear
  the whole pool down when idle and churn pool restarts, surfacing as
  transient `:pool_not_available` errors when traffic resumes, so it is left
  at its `:infinity` default. The transport timeout caps the TCP connect
  handshake at 10s, so an unreachable endpoint fails there rather than at the
  OS-level TCP timeout of 75-120s.
  """
  @spec default_options() :: keyword()
  def default_options do
    [size: 50, count: 1, conn_max_idle_time: 30_000]
    |> Keyword.merge(Application.get_env(:tymeslot, :finch_default_pool, []))
    |> Keyword.put(:conn_opts, transport_opts: [timeout: 10_000])
  end

  @doc """
  Returns the Req `:finch` option to reach `url` with `connect_options`.

  With no connection options the shared pool serves the request as it always
  did. With some, a pool carrying them is registered on the same instance
  under a tag derived from those options, so that two requests wanting the
  same connection settings to the same destination share one pool and two
  wanting different ones do not collide.

  `:error` means there is no Finch instance to register against — the test
  suite routes Req through a plug instead — and the caller should fall back to
  passing the connection options through to Req.
  """
  @spec request_option(String.t(), keyword()) :: {:ok, keyword()} | :error
  def request_option(_url, []), do: {:ok, [name: @finch]}

  def request_option(url, connect_options) do
    if running?() do
      pool_options = pool_options(connect_options)
      tag = tag_for(pool_options)

      Finch.start_pool(@finch, Pool.new(url, tag: tag), pool_options)
      {:ok, [name: @finch, pool_tag: tag]}
    else
      :error
    end
  end

  defp running?, do: is_pid(Process.whereis(@finch))

  # `Req.Finch.pool_options/1` is how Req itself turns `:connect_options` into
  # Finch pool configuration, so borrowing it keeps a pinned request connecting
  # on exactly the terms it did before this module existed. Only the pool's
  # identity changes, never the socket's.
  defp pool_options(connect_options) do
    Keyword.merge(
      default_options(),
      Req.Finch.pool_options(connect_options: connect_options),
      fn
        :conn_opts, ours, theirs -> merge_conn_opts(ours, theirs)
        _key, _ours, theirs -> theirs
      end
    )
  end

  defp merge_conn_opts(ours, theirs) do
    Keyword.merge(ours, theirs, fn
      :transport_opts, ours, theirs -> Keyword.merge(ours, theirs)
      _key, _ours, theirs -> theirs
    end)
  end

  # A binary, deliberately: a tag becomes part of the pool's registry key, and
  # an atom one would reintroduce the unbounded atom growth this module exists
  # to remove. Canonicalised first so that the same settings written in a
  # different order name the same pool.
  defp tag_for(pool_options) do
    pool_options
    |> canonical()
    |> :erlang.term_to_binary()
    |> :erlang.md5()
    |> Base.encode16(case: :lower)
  end

  defp canonical(list) when is_list(list) do
    if Keyword.keyword?(list) do
      list |> Enum.sort() |> Enum.map(fn {key, value} -> {key, canonical(value)} end)
    else
      list
    end
  end

  defp canonical(other), do: other
end
