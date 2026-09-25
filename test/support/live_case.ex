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
  alias Tymeslot.TestMocks

  using do
    quote do
      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import TymeslotWeb.ConnCase
      import Tymeslot.TestHelpers.Eventually

      # Routes generation with the ~p sigil
      unquote(TymeslotWeb.verified_routes())

      # The default endpoint for testing
      @endpoint TymeslotWeb.Endpoint

      defp wait_until(fun, timeout \\ 5000) do
        eventually(fun, timeout: timeout, interval: 100)
      end
    end
  end

  setup tags do
    DataCase.setup_sandbox(tags)
    DataCase.reset_stateful_components(tags)
    Mox.set_mox_from_context(tags)
    TestMocks.setup_subscription_mocks()
    {:ok, conn: ConnTest.build_conn()}
  end
end
