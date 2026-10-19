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

    # RateLimit (an ETS table) is always started in the supervision tree.
    # Clear its state for test isolation.
    RateLimiter.clear_all()

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
