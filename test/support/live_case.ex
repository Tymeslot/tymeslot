defmodule TymeslotWeb.LiveCase do
  @moduledoc """
  This module defines the test case to be used by
  LiveView tests.

  Such tests rely on `Phoenix.LiveViewTest` and also
  import other functionality to make it easier
  to build common data structures and test LiveView functionality.
  """

  use ExUnit.CaseTemplate

  alias Phoenix.ConnTest
  alias Tymeslot.DataCase

  using do
    quote do
      # The default endpoint for testing
      @endpoint TymeslotWeb.Endpoint

      use TymeslotWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import TymeslotWeb.LiveCase
    end
  end

  setup tags do
    DataCase.setup_sandbox(tags)
    {:ok, conn: ConnTest.build_conn()}
  end
end
