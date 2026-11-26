defmodule Tymeslot.Integrations.Stripe.ClientTest do
  # Not async: one test unsets the key in app env, and two assert on what the
  # suite-wide log and telemetry handlers did not see.
  use ExUnit.Case, async: false

  import Plug.Conn
  import Tymeslot.ConfigTestHelpers

  alias Req.Test, as: ReqTest
  alias Tymeslot.Integrations.Stripe
  alias Tymeslot.Integrations.Stripe.Client
  alias Tymeslot.Integrations.Stripe.Error
  alias Tymeslot.Integrations.Stripe.Request
  alias Tymeslot.Test.LogCapture

  @moduletag :payments

  @refund_body ~s({"id":"re_1","charge":{"amount_refunded":500}})

  # Records each request the stub receives, then answers with `respond`,
  # which gets the 1-based call number and the conn.
  defp stub_stripe(respond) do
    test_pid = self()
    calls = :counters.new(1, [])

    ReqTest.stub(Stripe, fn conn ->
      :counters.add(calls, 1, 1)
      {:ok, body, conn} = read_body(conn)

      send(
        test_pid,
        {:stripe_request,
         %{
           method: conn.method,
           path: conn.request_path,
           query: conn.query_string,
           headers: conn.req_headers,
           body: body
         }}
      )

      respond.(:counters.get(calls, 1), conn)
    end)
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
  end

  defp header(request, name) do
    Enum.find_value(request.headers, fn {key, value} -> key == name && value end)
  end

  defp refund_request(opts \\ []) do
    Request.new(
      :create_refund,
      :post,
      ["refunds"],
      %{charge: "ch_1", amount: 500},
      Keyword.merge([api_key: "sk_test_x"], opts)
    )
  end

  test "a POST sends the form body and the Stripe headers" do
    stub_stripe(fn _call, conn -> json(conn, 200, @refund_body) end)

    assert {:ok, _refund} =
             Client.run(refund_request(idempotency_key: "k1", connect_account: "acct_1"))

    assert_received {:stripe_request, request}
    assert request.method == "POST"
    assert request.path == "/v1/refunds"
    assert request.body == "amount=500&charge=ch_1"
    assert header(request, "authorization") == "Bearer sk_test_x"
    assert header(request, "stripe-version") == "2025-11-17.clover"
    assert header(request, "content-type") == "application/x-www-form-urlencoded"
    assert header(request, "idempotency-key") == "k1"
    assert header(request, "stripe-account") == "acct_1"
    assert header(request, "x-tymeslot-stripe-operation") == "create_refund"
  end

  test "a GET sends its params as the query" do
    stub_stripe(fn _call, conn -> json(conn, 200, ~s({"object":"list","data":[]})) end)

    request =
      Request.new(:list_refunds, :get, ["refunds"], [charge: "ch_1", limit: 100],
        api_key: "sk_test_x"
      )

    assert {:ok, %{"object" => "list"}} = Client.run(request)
    assert_received {:stripe_request, %{method: "GET", query: "charge=ch_1&limit=100", body: ""}}
  end

  test "a POST without a key gets a generated idempotency key, reused on retry" do
    stub_stripe(fn
      1, conn -> ReqTest.transport_error(conn, :timeout)
      _call, conn -> json(conn, 200, @refund_body)
    end)

    assert {:ok, %{"id" => "re_1"}} = Client.run(refund_request())

    assert_received {:stripe_request, first}
    assert_received {:stripe_request, second}
    refute_received {:stripe_request, _}

    key = header(first, "idempotency-key")
    assert "tymeslot-" <> random = key
    assert byte_size(random) == 24
    assert header(second, "idempotency-key") == key
  end

  test "a 2xx JSON object is returned string-keyed" do
    stub_stripe(fn _call, conn -> json(conn, 200, @refund_body) end)

    assert Client.run(refund_request()) ==
             {:ok, %{"id" => "re_1", "charge" => %{"amount_refunded" => 500}}}
  end

  test "a 2xx that is not a JSON object is an error" do
    stub_stripe(fn _call, conn -> json(conn, 200, ~s(["re_1"])) end)

    assert {:error,
            %Error{
              type: "api_error",
              status: 200,
              message: "unexpected response body",
              operation: :create_refund
            }} = Client.run(refund_request())
  end

  test "a Stripe error body becomes a Stripe.Error" do
    stub_stripe(fn _call, conn ->
      conn
      |> put_resp_header("request-id", "req_1")
      |> json(
        404,
        ~s({"error":{"type":"invalid_request_error","code":"resource_missing",) <>
          ~s("param":"charge","message":"No such charge: 'ch_1'"}})
      )
    end)

    assert {:error, error} = Client.run(refund_request())

    assert error == %Error{
             type: "invalid_request_error",
             code: "resource_missing",
             decline_code: nil,
             param: "charge",
             message: "No such charge: 'ch_1'",
             status: 404,
             request_id: "req_1",
             reason: nil,
             operation: :create_refund
           }
  end

  test "a POST 500 is not retried" do
    stub_stripe(fn _call, conn -> json(conn, 500, ~s({"error":{"type":"api_error"}})) end)

    assert {:error, %Error{type: "api_error", status: 500}} = Client.run(refund_request())
    assert_received {:stripe_request, _}
    refute_received {:stripe_request, _}
  end

  test "a GET 500 is retried once then succeeds" do
    stub_stripe(fn
      1, conn -> json(conn, 500, ~s({"error":{"type":"api_error"}}))
      _call, conn -> json(conn, 200, ~s({"id":"ch_1"}))
    end)

    request = Request.new(:retrieve_charge, :get, ["charges", "ch_1"], %{}, api_key: "sk_test_x")

    assert {:ok, %{"id" => "ch_1"}} = Client.run(request)
    assert_received {:stripe_request, %{method: "GET", path: "/v1/charges/ch_1"}}
    assert_received {:stripe_request, %{method: "GET"}}
    refute_received {:stripe_request, _}
  end

  test "three timeouts give three attempts and an api_connection_error" do
    stub_stripe(fn _call, conn -> ReqTest.transport_error(conn, :timeout) end)

    assert {:error, %Error{type: "api_connection_error", status: nil, reason: :timeout}} =
             Client.run(refund_request())

    for _attempt <- 1..3, do: assert_received({:stripe_request, _})
    refute_received {:stripe_request, _}
  end

  test "Finch failing to provide a connection is a connection error, retried and logged once" do
    LogCapture.attach()

    stub_stripe(fn _call, _conn ->
      raise "Finch was unable to provide a connection within the timeout due to excess queuing"
    end)

    assert {:error, %Error{type: "api_connection_error", status: nil} = error} =
             Client.run(refund_request())

    assert error.reason == {:raised, RuntimeError}
    for _attempt <- 1..3, do: assert_received({:stripe_request, _request})
    refute_received {:stripe_request, _request}

    failures =
      Enum.filter(LogCapture.drain(), &(LogCapture.dump(&1) =~ "Stripe request failed"))

    assert [event] = failures
    assert %{attempts: 3, reason: RuntimeError} = LogCapture.user_metadata(event)
  end

  test "Finch having no pool is a connection error" do
    stub_stripe(fn _call, _conn -> raise Finch.Error, :pool_not_available end)

    assert {:error, %Error{type: "api_connection_error", reason: {:raised, Finch.Error}}} =
             Client.run(refund_request())
  end

  test "any other exception propagates as the bug it is, without a retry" do
    for exception <- [ArgumentError, RuntimeError] do
      stub_stripe(fn _call, _conn -> raise exception, "bad option" end)

      assert_raise exception, "bad option", fn -> Client.run(refund_request()) end
      assert_received {:stripe_request, _request}
      refute_received {:stripe_request, _request}
    end
  end

  test "an exit in the HTTP stack is a connection error carrying only its reason" do
    stub_stripe(fn
      1, _conn -> exit({:timeout, {GenServer, :call, [:pool, "sk_test_x"]}})
      _call, conn -> json(conn, 200, @refund_body)
    end)

    assert {:ok, %{"id" => "re_1"}} = Client.run(refund_request())

    stub_stripe(fn _call, _conn -> exit({:timeout, {GenServer, :call, [:pool, "sk_test_x"]}}) end)

    assert {:error, %Error{type: "api_connection_error", reason: {:exit, :timeout}}} =
             Client.run(refund_request())
  end

  test "a call with no time left sends nothing" do
    stub_stripe(fn _call, conn -> json(conn, 200, @refund_body) end)

    assert {:error, %Error{type: "api_connection_error", reason: :deadline_exceeded}} =
             Client.run(%{refund_request() | deadline_ms: 0})

    refute_received {:stripe_request, _request}
  end

  test "req_options may not choose the transport" do
    settings = Application.get_env(:tymeslot, Stripe)

    for option <- [finch: [name: Tymeslot.Finch], connect_options: [timeout: 1]] do
      with_config(:tymeslot, Stripe, Keyword.update!(settings, :req_options, &[option | &1]))

      assert_raise ArgumentError, ~r/must not set/, fn -> Client.run(refund_request()) end
    end
  end

  test "a missing key returns :missing_api_key without a request" do
    with_config(:tymeslot, :stripe_secret_key, nil)
    stub_stripe(fn _call, conn -> json(conn, 200, @refund_body) end)

    request = Request.new(:create_refund, :post, ["refunds"], %{charge: "ch_1"})

    assert Client.run(request) == {:error, :missing_api_key}
    refute_received {:stripe_request, _}
  end

  test "the configured key is used when the request names none" do
    with_config(:tymeslot, :stripe_secret_key, "sk_test_cfg")
    stub_stripe(fn _call, conn -> json(conn, 200, @refund_body) end)

    assert {:ok, _refund} = Client.run(Request.new(:create_refund, :post, ["refunds"], %{}))
    assert_received {:stripe_request, request}
    assert header(request, "authorization") == "Bearer sk_test_cfg"
  end

  test "telemetry reports operation, attempts and request id" do
    test_pid = self()
    handler_id = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler_id,
      [:tymeslot, :integrations, :stripe, :request, :stop],
      fn _event, _measurements, metadata, _config -> send(test_pid, {:stripe_stop, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    stub_stripe(fn
      1, conn -> ReqTest.transport_error(conn, :closed)
      _call, conn -> conn |> put_resp_header("request-id", "req_ok") |> json(200, @refund_body)
    end)

    assert {:ok, _refund} = Client.run(refund_request(connect_account: "acct_1"))

    assert_received {:stripe_stop, metadata}

    assert Map.delete(metadata, :telemetry_span_context) == %{
             operation: :create_refund,
             method: :post,
             connect?: true,
             attempts: 2,
             status: 200,
             request_id: "req_ok",
             error_type: nil
           }
  end

  test "a final failure logs one warning without the key" do
    LogCapture.attach()

    stub_stripe(fn _call, conn ->
      json(conn, 400, ~s({"error":{"type":"invalid_request_error","code":"parameter_missing"}}))
    end)

    assert {:error, %Error{}} = Client.run(refund_request(api_key: "sk_test_LEAK"))

    event = LogCapture.await_log("Stripe request failed")

    assert event.level == :warning

    assert LogCapture.user_metadata(event) == %{
             operation: :create_refund,
             method: :post,
             status: 400,
             error_type: "invalid_request_error",
             code: "parameter_missing",
             request_id: nil,
             attempts: 1,
             reason: nil
           }
  end

  test "a 429 lock timeout is retried, while a rate-limit 429 is returned after one attempt" do
    stub_stripe(fn
      1, conn ->
        json(conn, 429, ~s({"error":{"type":"invalid_request_error","code":"lock_timeout"}}))

      2, conn ->
        json(conn, 200, @refund_body)

      _call, conn ->
        json(conn, 429, ~s({"error":{"type":"invalid_request_error","code":"rate_limit"}}))
    end)

    assert {:ok, _refund} = Client.run(refund_request())
    for _attempt <- 1..2, do: assert_received({:stripe_request, _request})

    assert {:error, %Error{status: 429, code: "rate_limit"}} = Client.run(refund_request())
    assert_received {:stripe_request, _request}
    refute_received {:stripe_request, _request}
  end

  test "a missing object or an unreachable connected account logs at debug, leaving the level to the caller" do
    LogCapture.attach(logger_level: :debug)

    stub_stripe(fn
      1, conn ->
        json(conn, 404, ~s({"error":{"type":"invalid_request_error","code":"resource_missing"}}))

      _call, conn ->
        json(conn, 403, ~s({"error":{"type":"invalid_request_error","code":"account_invalid"}}))
    end)

    request = Request.new(:retrieve_charge, :get, ["charges", "ch_1"], %{}, api_key: "sk_test_x")
    assert {:error, %Error{status: 404}} = Client.run(request)
    assert {:error, %Error{status: 403}} = Client.run(request)

    failures =
      Enum.filter(LogCapture.drain(), &(LogCapture.dump(&1) =~ "Stripe request failed"))

    assert [%{level: :debug} = missing, %{level: :debug} = unreachable] = failures
    assert %{status: 404, code: "resource_missing"} = LogCapture.user_metadata(missing)
    assert %{status: 403, code: "account_invalid"} = LogCapture.user_metadata(unreachable)
  end

  test "a 5xx that outlasts its retries logs a warning" do
    LogCapture.attach()
    stub_stripe(fn _call, conn -> json(conn, 503, ~s({"error":{"type":"api_error"}})) end)

    request = Request.new(:retrieve_charge, :get, ["charges", "ch_1"], %{}, api_key: "sk_test_x")
    assert {:error, %Error{status: 503}} = Client.run(request)

    event = LogCapture.await_log("Stripe request failed")
    assert event.level == :warning
    assert %{status: 503, attempts: 3} = LogCapture.user_metadata(event)
  end

  test "nothing logged contains the key" do
    LogCapture.attach(logger_level: :debug)

    stub_stripe(fn
      1, conn -> ReqTest.transport_error(conn, :timeout)
      2, conn -> json(conn, 503, ~s({"error":{"type":"api_error"}}))
      _call, conn -> json(conn, 401, ~s({"error":{"type":"invalid_request_error"}}))
    end)

    request =
      Request.new(:retrieve_charge, :get, ["charges", "ch_1"], %{}, api_key: "sk_test_LEAK")

    assert {:error, %Error{status: 401}} = Client.run(request)

    dumped = Enum.map(LogCapture.drain(), &LogCapture.dump/1)

    assert Enum.any?(dumped, &(&1 =~ "Stripe request failed"))
    assert Enum.filter(dumped, &(&1 =~ "LEAK")) == []
  end
end
