defmodule TymeslotWeb.OAuthIntegrationCase do
  @moduledoc """
  This module defines the test case to be used by OAuth integration tests.

  It extends ConnCase functionality to start required services like RateLimiter
  that are not normally started in test environment.
  """

  use ExUnit.CaseTemplate

  alias Phoenix.ConnTest
  alias Plug.Conn
  alias Tymeslot.DataCase
  alias Tymeslot.Security.AccountLockout
  alias Tymeslot.Security.RateLimiter

  using do
    quote do
      # The default endpoint for testing
      @endpoint TymeslotWeb.Endpoint

      use TymeslotWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import TymeslotWeb.ConnCase
    end
  end

  setup tags do
    DataCase.setup_sandbox(tags)

    # Start RateLimiter for OAuth integration tests
    rate_limiter_result =
      case Process.whereis(RateLimiter) do
        nil ->
          case RateLimiter.start_link([]) do
            {:ok, pid} ->
              {:started, pid}

            {:error, {:already_started, pid}} ->
              {:already_running, pid}
          end

        pid ->
          {:already_running, pid}
      end

    # Start AccountLockout for OAuth integration tests
    lockout_result =
      case Process.whereis(AccountLockout) do
        nil ->
          case AccountLockout.start_link([]) do
            {:ok, pid} ->
              {:started, pid}

            {:error, {:already_started, pid}} ->
              {:already_running, pid}
          end

        pid ->
          {:already_running, pid}
      end

    # Only stop processes we started
    on_exit(fn ->
      case rate_limiter_result do
        {:started, pid} when is_pid(pid) ->
          if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5000)

        _ ->
          :ok
      end

      case lockout_result do
        {:started, pid} when is_pid(pid) ->
          if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5000)

        _ ->
          :ok
      end
    end)

    {:ok, conn: setup_session(ConnTest.build_conn())}
  end

  @doc """
  Helper function to setup session on a test connection.
  """
  @spec setup_session(Plug.Conn.t()) :: Plug.Conn.t()
  def setup_session(conn) do
    conn
    |> Conn.put_private(:plug_session_fetch, :done)
    |> Conn.put_private(:plug_session, %{})
  end
end
