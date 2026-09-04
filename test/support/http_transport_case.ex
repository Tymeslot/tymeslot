defmodule Tymeslot.HttpTransportCase do
  @moduledoc """
  Shared ExUnit case template for tests that drive the real HTTP transport.

  The global test config points `:http_client_module` at `HTTPClientMock`, so
  transport-level behaviour (SSRF guards, redirect handling, response caps,
  header building) is invisible to a test that inherits it. This template
  overrides it with the real `Tymeslot.Infrastructure.HTTPClient`, so tests
  exercise the full `Req` → `Req.Test` path.

  It is transport-agnostic: CalDAV, ICS and any other integration that speaks
  HTTP through `HTTPClient` should use it. Provider-specific fixtures belong in
  the test file or a provider helper module, not here.

  Also provides `stub_sequential/2` for tests that need to route the first
  request to one handler and all subsequent requests to another.

  ## Usage

      defmodule MyTransportTest do
        use Tymeslot.HttpTransportCase
        ...
      end
  """

  alias Req.Test, as: ReqTest

  defmacro __using__(opts) do
    async = Keyword.get(opts, :async, false)

    quote do
      use ExUnit.Case, async: unquote(async)

      import Tymeslot.HttpTransportCase, only: [stub_sequential: 2]
      import Tymeslot.ConfigTestHelpers

      alias Plug.Conn
      alias Req.Test, as: ReqTest

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
