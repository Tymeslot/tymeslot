defmodule Tymeslot.StripeStub do
  @moduledoc """
  Answers `Tymeslot.Integrations.Stripe` calls at the HTTP level, by operation.

  In test the client sends every request to `{Req.Test,
  Tymeslot.Integrations.Stripe}` and names its operation (`:create_refund`,
  `:retrieve_charge`, as listed in each resource module's moduledoc) in the
  `x-tymeslot-stripe-operation` header. The first `stub/2`, `expect/3`,
  `allow/1` or `shared!/1` in a test installs one `Req.Test` stub that
  dispatches on that header, so the code under test runs its real request
  building, encoding, retries and decoding.

      setup do
        StripeStub.stub(:retrieve_charge, StripeFixtures.object("charge"))
        :ok
      end

      test "refunds the charge" do
        StripeStub.expect(:create_refund, StripeFixtures.object("refund"))
        ...
        assert [%{form: %{"charge" => "ch_test1"}}] = StripeStub.requests(:create_refund)
      end

  A response is one of:

    * a map, sent as a 200 JSON body;
    * `{status, body}`, with a map body sent as JSON and a binary sent as is;
    * `{:error_fixture, name}`, the status and body of
      `Tymeslot.StripeFixtures.error_body/1`;
    * `{:transport_error, reason}`, a failed connection
      (`Req.Test.transport_error/2`, so only reasons such as `:timeout`,
      `:closed` or `:econnrefused`);
    * a 1-arity function, called with the recorded request (see
      `requests/0`) and returning one of the above.

  For each request the queued `expect/3` responses for its operation are used
  first, in order, then its `stub/2` response. A request with neither is
  answered with a 500 whose message names the operation and path, marked
  `stripe-should-retry: false` so the client sends it once, and fails the test
  when it ends, as does an `expect/3` response left unused.

  The client retries a 409, a 429 whose code is `lock_timeout` (not a rate
  limit), a 5xx on a GET or DELETE, and a transport error, up to 3 attempts in
  all, so an `expect/3` of such a response on a GET needs 3 entries to reach
  the caller as a failure (or use `stub/2`). A 5xx on a POST and a rate-limit
  429 are not retried.

  Requests are answered for the test process and every process that follows
  it through `$callers` (see `allow/1`); `shared!/1` widens that to every
  process.

  The state lives in an unlinked `Agent` rather than one tied to the test
  process, so it is still there when `on_exit/1` checks it.
  """

  import ExUnit.Assertions, only: [flunk: 1]
  import ExUnit.Callbacks, only: [on_exit: 1]

  alias Plug.Conn
  alias Plug.Conn.Query
  alias Req.Test, as: ReqTest
  alias Tymeslot.StripeFixtures

  @stub_name Tymeslot.Integrations.Stripe
  @operation_header "x-tymeslot-stripe-operation"
  @agent_key {__MODULE__, :agent}

  @type request :: %{
          operation: atom(),
          method: atom(),
          path: String.t(),
          form: map(),
          query: map(),
          headers: %{String.t() => String.t()}
        }

  @type response ::
          map()
          | {pos_integer(), map() | binary()}
          | {:error_fixture, String.t()}
          | {:transport_error, atom()}
          | (request() -> response())

  @doc """
  Answers every request for `operation` with `response` once its queued
  expectations are used. A later call replaces the earlier response.
  """
  @spec stub(atom(), response()) :: :ok
  def stub(operation, response) when is_atom(operation) do
    Agent.update(install!(), &put_in(&1, [:stubs, operation], response))
  end

  @doc """
  Queues `response` for the next `times` requests for `operation`. Each must
  be used before the test ends.
  """
  @spec expect(atom(), pos_integer(), response()) :: :ok
  def expect(operation, times \\ 1, response)
      when is_atom(operation) and is_integer(times) and times > 0 do
    queued = List.duplicate(response, times)

    Agent.update(install!(), fn state ->
      update_in(
        state.expects,
        &Map.update(&1, operation, queued, fn queue -> queue ++ queued end)
      )
    end)
  end

  @doc """
  Every request the stub received in this test, oldest first. Callable from
  the test process or a process started from it (found through `$callers`);
  raises `ArgumentError` where no stub was installed.

  Each is `%{operation, method, path, form, query, headers}`: `method` a
  lowercase atom, `path` such as `"/v1/refunds"`, `form` the decoded POST
  body and `query` the decoded query string (both `%{}` when absent, with
  Stripe's indexed arrays, `expand[0]=charge`, as lists), and `headers` a map
  of lowercase names to values.
  """
  @spec requests() :: [request()]
  def requests do
    agent!() |> Agent.get(& &1.requests) |> Enum.reverse()
  end

  @doc """
  The requests for `operation`, oldest first.
  """
  @spec requests(atom()) :: [request()]
  def requests(operation) when is_atom(operation) do
    Enum.filter(requests(), &(&1.operation == operation))
  end

  @doc """
  Lets `pid` use this test's stub. Not available in shared mode.

  Most processes need no `allow/1`: `Req.Test` follows `$callers`, so a
  LiveView started by `Phoenix.LiveViewTest`, its `start_async` tasks, any
  `Task` and an Oban job run inline from one of them already reach the stub.
  `allow/1` is for processes outside that chain: a plain `spawn`, or a
  GenServer started elsewhere (for example under the application's
  supervisor).
  """
  @spec allow(pid()) :: :ok
  def allow(pid) when is_pid(pid) do
    install!()
    :ok = ReqTest.allow(@stub_name, self(), pid)
  end

  @doc """
  Hands this test's stub to every process on the node, for callers that are
  neither in the test's `$callers` chain nor can be named for `allow/1`.
  Takes the ExUnit context, so it works as `setup {StripeStub, :shared!}`,
  and raises in an `async: true` module, where another test's Stripe calls
  would reach this stub.
  """
  @spec shared!(map()) :: :ok
  def shared!(%{async: false}) do
    :ok = ReqTest.set_req_test_to_shared(%{})
    install!()
    :ok
  end

  def shared!(context) do
    raise ArgumentError,
          "StripeStub.shared!/1 needs an async: false test module, got async: " <>
            inspect(context[:async])
  end

  @doc """
  Fails if a request had no response or an `expect/3` response is unused,
  listing them. What it reports is then forgotten, so the check that runs
  when the test ends does not report it again. A test of the stub itself can
  call it directly. Finds the stub as `requests/0` does.
  """
  @spec verify!() :: :ok
  def verify!, do: verify_agent!(agent!())

  defp agent! do
    case Enum.find_value([self() | Process.get(:"$callers", [])], &agent_of/1) do
      nil ->
        raise ArgumentError,
              "StripeStub: no stub installed by this process or its $callers; " <>
                "call stub/2, expect/3, allow/1 or shared!/1 in the test process first"

      agent ->
        agent
    end
  end

  defp agent_of(pid) when pid == self(), do: Process.get(@agent_key)

  defp agent_of(pid) do
    with {:dictionary, dictionary} <- Process.info(pid, :dictionary),
         {@agent_key, agent} <- List.keyfind(dictionary, @agent_key, 0) do
      agent
    else
      _not_found -> nil
    end
  end

  defp install! do
    case Process.get(@agent_key) do
      nil ->
        {:ok, agent} =
          Agent.start(fn -> %{expects: %{}, stubs: %{}, requests: [], unexpected: []} end)

        Process.put(@agent_key, agent)
        :ok = ReqTest.stub(@stub_name, &dispatch(&1, agent))

        on_exit(fn ->
          try do
            verify_agent!(agent)
          after
            Agent.stop(agent)
          end
        end)

        agent

      agent ->
        agent
    end
  end

  defp verify_agent!(agent) do
    {unexpected, unused} =
      Agent.get_and_update(agent, fn state ->
        unused = for {op, [_next | _rest] = queue} <- state.expects, do: {op, length(queue)}

        {{Enum.reverse(state.unexpected), unused},
         %{
           state
           | unexpected: [],
             expects: Map.new(state.expects, fn {op, _queue} -> {op, []} end)
         }}
      end)

    case failure_lines(unexpected, unused) do
      [] -> :ok
      lines -> flunk(Enum.join(["StripeStub:" | lines], "\n"))
    end
  end

  defp failure_lines(unexpected, unused) do
    unexpected_lines =
      for request <- unexpected,
          do: "  unexpected request #{describe(request)} (no stub or expect for this operation)"

    unused_lines =
      for {op, count} <- unused,
          do: "  #{op}: #{count} expected #{plural(count)} not used"

    unexpected_lines ++ unused_lines
  end

  defp plural(1), do: "response"
  defp plural(_count), do: "responses"

  defp describe(request) do
    "#{request.operation} #{request.method |> Atom.to_string() |> String.upcase()} #{request.path}"
  end

  defp dispatch(conn, agent) do
    request = record(conn)

    response =
      Agent.get_and_update(agent, fn state ->
        state = %{state | requests: [request | state.requests]}

        case Map.get(state.expects, request.operation, []) do
          [next | rest] ->
            {{:ok, next}, put_in(state.expects[request.operation], rest)}

          [] ->
            case Map.fetch(state.stubs, request.operation) do
              {:ok, stubbed} -> {{:ok, stubbed}, state}
              :error -> {:unexpected, %{state | unexpected: [request | state.unexpected]}}
            end
        end
      end)

    case response do
      {:ok, response} -> respond(conn, resolve(response, request))
      :unexpected -> respond_unexpected(conn, request)
    end
  end

  defp resolve(fun, request) when is_function(fun, 1), do: resolve(fun.(request), request)
  defp resolve({:error_fixture, name}, _request), do: StripeFixtures.error_body(name)
  defp resolve(response, _request), do: response

  defp respond(conn, {:transport_error, reason}), do: ReqTest.transport_error(conn, reason)
  defp respond(conn, %{} = body), do: respond(conn, {200, body})

  defp respond(conn, {status, %{} = body}) when is_integer(status),
    do: respond(conn, {status, Jason.encode!(body)})

  defp respond(conn, {status, body}) when is_integer(status) and is_binary(body) do
    conn
    |> Conn.put_resp_content_type("application/json")
    |> Conn.send_resp(status, body)
  end

  defp respond(_conn, other) do
    raise ArgumentError, "StripeStub: not a response: #{inspect(other)}"
  end

  defp respond_unexpected(conn, request) do
    message = "StripeStub: no stub or expect for #{describe(request)}"

    conn
    |> Conn.put_resp_header("stripe-should-retry", "false")
    |> respond({500, %{"error" => %{"type" => "api_error", "message" => message}}})
  end

  defp record(conn) do
    {:ok, body, conn} = Conn.read_body(conn)

    %{
      operation: operation!(conn),
      method: conn.method |> String.downcase() |> String.to_existing_atom(),
      path: conn.request_path,
      form: decode(body),
      query: decode(conn.query_string),
      headers: Map.new(conn.req_headers)
    }
  end

  # An operation no resource module defines is a bug in the client's
  # tagging, so the conversion is left to raise.
  defp operation!(conn) do
    case Conn.get_req_header(conn, @operation_header) do
      [operation] ->
        String.to_existing_atom(operation)

      [] ->
        raise "StripeStub: #{conn.method} #{conn.request_path} carries no " <>
                "#{@operation_header} header; is tag_requests set in the test config?"
    end
  end

  defp decode(""), do: %{}
  defp decode(encoded), do: encoded |> Query.decode() |> listify()

  # Plug decodes `expand[0]=a&expand[1]=b` to `%{"0" => "a", "1" => "b"}`.
  defp listify(%{} = map) when map_size(map) > 0 do
    map = Map.new(map, fn {key, value} -> {key, listify(value)} end)
    indices = Enum.map(0..(map_size(map) - 1)//1, &Integer.to_string/1)

    if Enum.all?(indices, &Map.has_key?(map, &1)),
      do: Enum.map(indices, &Map.fetch!(map, &1)),
      else: map
  end

  defp listify(list) when is_list(list), do: Enum.map(list, &listify/1)
  defp listify(value), do: value
end
