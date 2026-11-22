defmodule Tymeslot.Integrations.Stripe.Client do
  @moduledoc """
  Sends a `Tymeslot.Integrations.Stripe.Request` and returns Stripe's answer.
  Internal to `Tymeslot.Integrations.Stripe`: the resource modules are the only
  callers.

  The client makes no decisions of its own. It resolves the key, gives a POST
  without one an idempotency key that every retry reuses, sends the request and
  asks `Tymeslot.Integrations.Stripe.RetryPolicy` whether to try again and how
  long each attempt may wait. A failure is described by
  `Tymeslot.Integrations.Stripe.Error`; a raise or exit from the HTTP stack
  counts as a transport failure, so it is retried and returned like one.

  The request's `deadline_ms` bounds the whole call, from before a pooled
  connection is leased to the last response: each attempt's receive and pool
  checkout waits are capped at the time left, and no attempt starts once it is
  gone.

  The whole call is one telemetry span, `[:tymeslot, :integrations, :stripe,
  :request]`, with metadata `operation`, `method`, `connect?` and, on stop,
  `attempts`, `status`, `request_id` and `error_type`. A final failure logs one
  warning with the same keys plus Stripe's error `code`. Neither ever carries
  the key, a header or a body.

  Settings (`config :tymeslot, Tymeslot.Integrations.Stripe`): `base_url`,
  `retry_base_ms`, `req_options` (merged into the Req request; the test suite
  routes it through `Req.Test` this way; `:finch` and `:connect_options` are
  refused, since the client chooses the transport) and `tag_requests`, which
  adds an `x-tymeslot-stripe-operation` header so test stubs can tell calls
  apart.
  """

  alias Tymeslot.Infrastructure.FinchPool
  alias Tymeslot.Integrations.Stripe
  alias Tymeslot.Integrations.Stripe.Error
  alias Tymeslot.Integrations.Stripe.Request
  alias Tymeslot.Integrations.Stripe.RetryPolicy

  require Logger

  @event [:tymeslot, :integrations, :stripe, :request]
  @transport_options [:finch, :connect_options]

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
    req_options = req_options!(settings)

    start_meta = %{
      operation: request.operation,
      method: request.method,
      connect?: request.connect_account != nil
    }

    :telemetry.span(@event, start_meta, fn ->
      started_at = now()

      with_transport(request, settings, req_options, fn transport ->
        call = %{
          req: build(request, settings, req_options, transport),
          request: request,
          transport: transport,
          base_ms: settings[:retry_base_ms],
          started_at: started_at
        }

        {result, summary} = attempt(call, 1, nil)
        log_failure(result, request, summary)
        {result, Map.merge(start_meta, summary)}
      end)
    end)
  end

  defp req_options!(settings) do
    options = settings[:req_options]

    case Enum.filter(@transport_options, &Keyword.has_key?(options, &1)) do
      [] ->
        options

      keys ->
        raise ArgumentError,
              "req_options for Tymeslot.Integrations.Stripe must not set #{inspect(keys)}: " <>
                "the client chooses the transport and its timeouts"
    end
  end

  # Req refuses `:finch` together with `:connect_options`, so the connect
  # timeout reaches the shared `Tymeslot.Finch` instance as a tagged pool
  # (see `FinchPool`). A test plug opens no socket and needs neither.
  defp with_transport(request, settings, req_options, fun) do
    connect_options = [timeout: request.connect_timeout]

    if Keyword.has_key?(req_options, :plug) do
      fun.([])
    else
      FinchPool.with_pool(settings[:base_url], connect_options, fn
        {:ok, finch} -> fun.(finch: finch)
        :error -> fun.(connect_options: connect_options)
      end)
    end
  end

  defp build(request, settings, req_options, transport) do
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
        decode_body: false
      ] ++ transport

    Req.merge(Req.new(options), req_options)
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

  defp attempt(call, number, last_error) do
    case RetryPolicy.attempt_timeouts(call.request, now() - call.started_at) do
      :expired ->
        error = last_error || Error.from_transport(:deadline_exceeded, call.request.operation)
        failed(error, number - 1)

      {:ok, timeouts} ->
        sent_at = now()
        response = send_once(Req.merge(call.req, timeout_options(call.transport, timeouts)))
        finished_at = now()

        case interpret(response, call.request.operation) do
          {:ok, map, meta} ->
            {{:ok, map}, Map.merge(meta, %{attempts: number, error_type: nil})}

          {:error, error, outcome} ->
            inputs = %{
              outcome: outcome,
              attempt: number,
              elapsed_ms: finished_at - call.started_at,
              last_attempt_ms: finished_at - sent_at,
              random: :rand.uniform(),
              base_ms: call.base_ms
            }

            retry_or_stop(call, number, error, inputs)
        end
    end
  end

  defp retry_or_stop(call, number, error, inputs) do
    case RetryPolicy.decide(call.request, inputs) do
      {:retry, delay} ->
        pause(delay)
        attempt(call, number + 1, error)

      :stop ->
        failed(error, number)
    end
  end

  defp failed(error, attempts) do
    {{:error, error},
     %{
       attempts: attempts,
       status: error.status,
       request_id: error.request_id,
       error_type: error.type
     }}
  end

  defp timeout_options(transport, timeouts) do
    case Keyword.fetch(transport, :finch) do
      {:ok, finch} ->
        [
          receive_timeout: timeouts.receive_timeout,
          finch: Keyword.put(finch, :pool_timeout, timeouts.pool_timeout)
        ]

      :error ->
        [receive_timeout: timeouts.receive_timeout]
    end
  end

  # Finch raises when no pooled connection frees up in time, and a pool can
  # exit under a call. Only the exception's module or the exit's reason atom is
  # kept: an exception message or a Req struct can carry request headers.
  defp send_once(req) do
    Req.request(req)
  rescue
    exception -> {:error, {:raised, exception.__struct__}}
  catch
    :exit, reason -> {:error, {:exit, exit_reason(reason)}}
  end

  defp exit_reason(reason) when is_atom(reason), do: reason
  defp exit_reason({reason, _detail}) when is_atom(reason), do: reason
  defp exit_reason(_reason), do: :unknown

  defp interpret({:ok, %Req.Response{status: status} = response}, operation)
       when status in 200..299 do
    headers = header_list(response)

    case Jason.decode(response.body) do
      {:ok, %{} = map} ->
        {:ok, map, %{status: status, request_id: Error.request_id(headers)}}

      _not_an_object ->
        {:error, Error.unexpected_body(status, headers, operation), {:response, status, headers}}
    end
  end

  defp interpret({:ok, %Req.Response{status: status, body: body} = response}, operation) do
    headers = header_list(response)
    {:error, Error.from_response(status, headers, body, operation), {:response, status, headers}}
  end

  defp interpret({:error, %Req.TransportError{reason: reason}}, operation) do
    phase = RetryPolicy.transport_phase(reason)
    {:error, Error.from_transport(reason, operation), {:transport, phase, reason}}
  end

  defp interpret({:error, %module{}}, operation), do: transport_failure(module, operation)
  defp interpret({:error, reason}, operation), do: transport_failure(reason, operation)

  defp transport_failure(reason, operation) do
    {:error, Error.from_transport(reason, operation), {:transport, :after_send, reason}}
  end

  defp header_list(%Req.Response{headers: headers}) do
    for {name, values} <- headers, value <- List.wrap(values), do: {name, value}
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
