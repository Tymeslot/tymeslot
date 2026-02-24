defmodule Tymeslot.CalDAVCase do
  @moduledoc """
  Shared ExUnit case template for CalDAV integration tests.

  Sets up the real HTTPClient so tests exercise the full Req → Req.Test path,
  and provides a `stub_sequential/2` helper for tests that need to route the
  first request to one handler and all subsequent requests to another.

  ## Usage

      defmodule MyCalDAVTest do
        use Tymeslot.CalDAVCase
        ...
      end
  """

  alias Req.Test, as: ReqTest

  defmacro __using__(opts) do
    async = Keyword.get(opts, :async, false)

    quote do
      use ExUnit.Case, async: unquote(async)

      import Tymeslot.CalDAVCase, only: [stub_sequential: 2]
      import Tymeslot.ConfigTestHelpers

      alias Plug.Conn
      alias Req.Test, as: ReqTest
      alias Tymeslot.Integrations.Calendar.CalDAV.Base

      setup do
        with_config(:tymeslot, :http_client_module, Tymeslot.Infrastructure.HTTPClient)
        :ok
      end
    end
  end

  @doc """
  Stubs the HTTP client so `first` handles the first request and `second`
  handles all subsequent requests. Both receive a `Plug.Conn` and must return one.
  """
  @spec stub_sequential(
          (Plug.Conn.t() -> Plug.Conn.t()),
          (Plug.Conn.t() -> Plug.Conn.t())
        ) :: :ok
  def stub_sequential(first, second) do
    call_count = :counters.new(1, [:atomics])

    ReqTest.stub(:tymeslot_http, fn conn ->
      :counters.add(call_count, 1, 1)
      n = :counters.get(call_count, 1)
      if n == 1, do: first.(conn), else: second.(conn)
    end)
  end
end
