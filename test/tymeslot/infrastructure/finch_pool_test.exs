defmodule Tymeslot.Infrastructure.FinchPoolTest do
  @moduledoc """
  Connection pinning gives every SSRF-guarded request its own connect options,
  and Req answers connect options by starting a Finch instance of its own. That
  is the behaviour these tests pin shut: the request must stay on
  `Tymeslot.Finch`, and the pool it lands on must carry the options it asked
  for.
  """
  use ExUnit.Case, async: false

  @moduletag :infrastructure
  @moduletag :unit

  alias Finch.Pool
  alias Tymeslot.Infrastructure.FinchPool

  describe "request_option/2" do
    test "asks for the shared pool by name when there is nothing to configure" do
      assert FinchPool.request_option("https://hooks.example.com/notify", []) ==
               {:ok, [name: Tymeslot.Finch]}
    end

    test "keeps the request on the shared instance when there is" do
      assert {:ok, options} =
               FinchPool.request_option("https://93.184.216.34/notify",
                 hostname: "hooks.example.com"
               )

      assert options[:name] == Tymeslot.Finch
      assert options[:pool_tag] =~ ~r/^[0-9a-f]{32}$/
    end

    test "names the pool with a binary, never an atom" do
      # The tag becomes part of the pool's registry key. An atom one would put
      # the destination host into the atom table, which is never collected, and
      # webhook destinations are supplied by users.
      # One warm-up call first: the very first pool registration loads modules
      # and creates their atoms once, which is not what this is about.
      {:ok, _warm} =
        FinchPool.request_option("https://93.184.216.99/notify", hostname: "warm.example.com")

      before = :erlang.system_info(:atom_count)

      for n <- 1..25 do
        {:ok, options} =
          FinchPool.request_option("https://93.184.216.#{n}/notify",
            hostname: "host#{n}.example.com"
          )

        assert options[:pool_tag] =~ ~r/^[0-9a-f]{32}$/
      end

      assert :erlang.system_info(:atom_count) == before
    end

    test "registers the pool it names on the shared instance" do
      url = "https://93.184.216.34:8443/notify"
      connect_options = [hostname: "pinned.example.com"]

      assert {:ok, options} = FinchPool.request_option(url, connect_options)

      assert {:ok, pid} =
               Finch.find_pool(Tymeslot.Finch, Pool.new(url, tag: options[:pool_tag]))

      assert is_pid(pid)
    end

    test "two requests wanting the same connection share one pool" do
      url = "https://93.184.216.35/notify"

      assert {:ok, first} = FinchPool.request_option(url, hostname: "same.example.com")
      assert {:ok, second} = FinchPool.request_option(url, hostname: "same.example.com")

      assert first[:pool_tag] == second[:pool_tag]
    end

    test "the same connection options in a different order still share one pool" do
      url = "https://93.184.216.36/notify"
      opts = [hostname: "ordered.example.com", transport_opts: [verify: :verify_none]]

      assert {:ok, first} = FinchPool.request_option(url, opts)
      assert {:ok, second} = FinchPool.request_option(url, Enum.reverse(opts))

      assert first[:pool_tag] == second[:pool_tag]
    end

    test "two requests wanting different connections do not collide" do
      url = "https://93.184.216.37/notify"

      assert {:ok, verified} = FinchPool.request_option(url, hostname: "a.example.com")

      assert {:ok, unverified} =
               FinchPool.request_option(url,
                 hostname: "a.example.com",
                 transport_opts: [verify: :verify_none]
               )

      refute verified[:pool_tag] == unverified[:pool_tag]
    end
  end

  describe "default_options/0" do
    test "carries the connect timeout where Mint actually reads it" do
      # Mint takes the socket's connect timeout from `transport_opts`, and
      # ignores a `:timeout` sitting at the top of the connection options. A
      # cap written in the wrong place is not a cap: an unreachable endpoint
      # would stall on the OS-level TCP timeout instead.
      assert FinchPool.default_options()[:conn_opts][:transport_opts][:timeout] == 10_000
    end

    test "evicts idle connections rather than tearing the pool down" do
      options = FinchPool.default_options()

      assert options[:conn_max_idle_time] == 30_000
      refute Keyword.has_key?(options, :pool_max_idle_time)
    end
  end

  describe "options the caller asked for" do
    test "reach the pool alongside the application's own" do
      url = "https://93.184.216.38/EWS/Exchange.asmx"

      {:ok, options} =
        FinchPool.request_option(url,
          hostname: "exchange.example.com",
          transport_opts: [verify: :verify_none]
        )

      {:ok, pid} = Finch.find_pool(Tymeslot.Finch, Pool.new(url, tag: options[:pool_tag]))

      # The pool's own state is the only place the merged configuration is
      # observable, and it is what the socket is opened with.
      conn_opts = pool_conn_opts(pid)

      assert conn_opts[:hostname] == "exchange.example.com"
      assert conn_opts[:transport_opts][:verify] == :verify_none
      assert conn_opts[:transport_opts][:timeout] == 10_000
    end
  end

  # The pool process's own state is the only place the merged configuration is
  # observable, and it is what the socket is opened with.
  defp pool_conn_opts(pid) do
    %{state: %{opts: %{conn_opts: conn_opts}}} = :sys.get_state(pid)
    conn_opts
  end
end
