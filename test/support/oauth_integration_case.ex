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

    # RateLimit (Hammer ETS) and AccountLockout are always started in the
    # supervision tree. Clear their state for test isolation.
    RateLimiter.clear_all()

    # Start AccountLockout if not already running (it is in the supervision tree,
    # but guard defensively for isolated test runs)
    lockout_result =
      case Process.whereis(AccountLockout) do
        nil ->
          case AccountLockout.start_link([]) do
            {:ok, pid} -> {:started, pid}
            {:error, {:already_started, pid}} -> {:already_running, pid}
          end

        pid ->
          {:already_running, pid}
      end

    # Only stop the AccountLockout process if we started it ourselves
    on_exit(fn ->
      case lockout_result do
        {:started, pid} when is_pid(pid) ->
          if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5000)

        _other ->
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
