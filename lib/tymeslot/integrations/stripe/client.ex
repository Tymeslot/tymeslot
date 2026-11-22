defmodule Tymeslot.Integrations.Stripe.Client do
  @moduledoc """
  Sends a `Tymeslot.Integrations.Stripe.Request` and returns Stripe's answer.
  Internal to `Tymeslot.Integrations.Stripe`: the resource modules are the only
  callers.

  The client makes no decisions of its own. It resolves the key, gives a POST
  without one an idempotency key that every retry reuses, sends the request and
  asks `Tymeslot.Integrations.Stripe.RetryPolicy` whether to try again. A
  failure is described by `Tymeslot.Integrations.Stripe.Error`.

  The whole call is one telemetry span, `[:tymeslot, :integrations, :stripe,
  :request]`, with metadata `operation`, `method`, `connect?` and, on stop,
  `attempts`, `status`, `request_id` and `error_type`. A final failure logs one
  warning with the same keys plus Stripe's error `code`. Neither ever carries
  the key, a header or a body.

  Settings (`config :tymeslot, Tymeslot.Integrations.Stripe`): `base_url`,
  `retry_base_ms`, `req_options` (merged into the Req request; the test suite
  routes it through `Req.Test` this way) and `tag_requests`, which adds an
  `x-tymeslot-stripe-operation` header so test stubs can tell calls apart.
  """

  alias Tymeslot.Infrastructure.FinchPool
  alias Tymeslot.Integrations.Stripe
  alias Tymeslot.Integrations.Stripe.Error
  alias Tymeslot.Integrations.Stripe.Request
  alias Tymeslot.Integrations.Stripe.RetryPolicy

  require Logger

  @event [:tymeslot, :integrations, :stripe, :request]

  # Reasons Mint reports before any byte of the request left. A connect
  # timeout is reported as plain `:timeout`, like a receive timeout, so it
  # counts as after-send; the retry rules treat both phases alike.
  @connect_reasons [:econnrefused, :nxdomain, :ehostunreach]

  @doc """
  Sends `request`, retrying as `RetryPolicy` decides.
  """
  @spec run(Request.t()) :: {:ok, map()} | {:error, Error.t() | :missing_api_key}
  def run(%Request{} = request) do
    case request.api_key || Stripe.secret_key() do
      nil -> {:error, :missing_api_key}
      key -> request |> Map.put(:api_key, key) |> with_idempotency_key() |> send_request()
    end
  end

  defp with_idempotency_key(%Request{method: :post, idempotency_key: nil} = request) do
    random = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    %{request | idempotency_key: "tymeslot-" <> random}
  end

  defp with_idempotency_key(request), do: request

  defp send_request(request) do
    settings = Stripe.settings()

    start_meta = %{
      operation: request.operation,
      method: request.method,
      connect?: request.connect_account != nil
    }

    :telemetry.span(@event, start_meta, fn ->
      with_transport(request, settings, fn transport ->
        req = build(request, settings, transport)
        {result, summary} = attempt(req, request, settings[:retry_base_ms], 1, now())
        log_failure(result, request, summary)
        {result, Map.merge(start_meta, summary)}
      end)
    end)
  end

  # Req refuses `:finch` together with `:connect_options`, so the connect
  # timeout reaches the shared `Tymeslot.Finch` instance as a tagged pool
  # (see `FinchPool`). A test plug opens no socket and needs neither.
  defp with_transport(request, settings, fun) do
    connect_options = [timeout: request.connect_timeout]

    if Keyword.has_key?(settings[:req_options], :plug) do
      fun.([])
    else
      FinchPool.with_pool(settings[:base_url], connect_options, fn
        {:ok, finch} -> fun.(finch: finch)
        :error -> fun.(connect_options: connect_options)
      end)
    end
  end

  defp build(request, settings, transport) do
    {body, query} = Request.body_and_query(request)

    options =
      [
        base_url: settings[:base_url],
        url: url(request, query),
        method: request.method,
        headers: headers(request, settings),
        body: body,
        retry: false,
        redirect: false,
        decode_body: false,
        receive_timeout: request.receive_timeout
      ] ++ transport

    Req.merge(Req.new(options), settings[:req_options])
  end

  defp url(request, nil), do: Request.url_path(request)
  defp url(request, query), do: Request.url_path(request) <> "?" <> query

  defp headers(request, settings) do
    tag =
      if settings[:tag_requests],
        do: [{"x-tymeslot-stripe-operation", Atom.to_string(request.operation)}],
        else: []

    Request.headers(request, Stripe.api_version()) ++ tag
  end

  defp attempt(req, request, base_ms, number, started_at) do
    sent_at = now()
    response = Req.request(req)
    finished_at = now()

    case interpret(response, request.operation) do
      {:ok, map, meta} ->
        {{:ok, map}, Map.merge(meta, %{attempts: number, error_type: nil})}

      {:error, error, outcome} ->
        inputs = %{
          outcome: outcome,
          attempt: number,
          elapsed_ms: finished_at - started_at,
          last_attempt_ms: finished_at - sent_at,
          random: :rand.uniform(),
          base_ms: base_ms
        }

        case RetryPolicy.decide(request, inputs) do
          {:retry, delay} ->
            pause(delay)
            attempt(req, request, base_ms, number + 1, started_at)

          :stop ->
            {{:error, error},
             %{
               attempts: number,
               status: error.status,
               request_id: error.request_id,
               error_type: error.type
             }}
        end
    end
  end

  defp interpret({:ok, %Req.Response{status: status} = response}, operation)
       when status in 200..299 do
    headers = header_list(response)
    request_id = request_id(headers)

    case Jason.decode(response.body) do
      {:ok, %{} = map} ->
        {:ok, map, %{status: status, request_id: request_id}}

      _not_an_object ->
        error = %Error{
          type: "api_error",
          status: status,
          request_id: request_id,
          message: "unexpected response body",
          operation: operation
        }

        {:error, error, {:response, status, headers}}
    end
  end

  defp interpret({:ok, %Req.Response{status: status, body: body} = response}, operation) do
    headers = header_list(response)
    {:error, Error.from_response(status, headers, body, operation), {:response, status, headers}}
  end

  defp interpret({:error, %Req.TransportError{reason: reason}}, operation) do
    {:error, Error.from_transport(reason, operation), {:transport, phase(reason), reason}}
  end

  defp interpret({:error, exception}, operation) do
    {:error, Error.from_transport(exception, operation), {:transport, :after_send, exception}}
  end

  defp phase(reason) when reason in @connect_reasons, do: :connect
  defp phase(_reason), do: :after_send

  defp header_list(%Req.Response{headers: headers}) do
    for {name, values} <- headers, value <- List.wrap(values), do: {name, value}
  end

  defp request_id(headers) do
    Enum.find_value(headers, fn {name, value} -> name == "request-id" && value end)
  end

  defp log_failure({:ok, _map}, _request, _summary), do: :ok

  defp log_failure({:error, error}, request, summary) do
    Logger.warning("Stripe request failed",
      operation: request.operation,
      method: request.method,
      status: summary.status,
      error_type: summary.error_type,
      code: error.code,
      request_id: summary.request_id,
      attempts: summary.attempts
    )
  end

  defp pause(0), do: :ok
  defp pause(delay_ms), do: Process.sleep(delay_ms)

  defp now, do: System.monotonic_time(:millisecond)
end
