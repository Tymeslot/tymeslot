defmodule Tymeslot.StripeLiveFlow do
  @moduledoc """
  The step runner behind the Stripe live suite. A flow is a list of steps run
  in order through `step/3` or `step/4`; each is recorded in
  `Tymeslot.StripeLiveReport` whatever happens, so one failure never hides the
  rest, and `failed_steps/1` lets the test fail afterwards if any step failed.

  A step's function returns `{:ok, value}`, `{:error, reason}`,
  `{:skip, reason}`, or `{:recorded_error, error}` for a call whose expected
  outcome is a Stripe error (the error shape is recorded and the step is ok).
  """

  alias Tymeslot.Integrations.Stripe.Accounts
  alias Tymeslot.Integrations.Stripe.Client
  alias Tymeslot.Integrations.Stripe.Customers
  alias Tymeslot.Integrations.Stripe.Error
  alias Tymeslot.Integrations.Stripe.Request
  alias Tymeslot.Integrations.Stripe.Subscriptions
  alias Tymeslot.StripeFixtures
  alias Tymeslot.StripeLiveContract
  alias Tymeslot.StripeLiveReport

  @no_key "STRIPE_TEST_SECRET_KEY not set"
  @secret ~r/[sr]k_(test|live)_[A-Za-z0-9*]+/

  defstruct [:report, :name, live?: false, record?: false]

  @type t :: %__MODULE__{}

  @spec new(pid(), String.t(), keyword()) :: t()
  def new(report, name, opts), do: struct!(%__MODULE__{report: report, name: name}, opts)

  @doc "The reason every step is skipped when no key is configured."
  @spec no_key_reason() :: String.t()
  def no_key_reason, do: @no_key

  @spec step(t(), String.t(), (-> term())) :: term()
  def step(flow, operation, fun) when is_function(fun, 0), do: step(flow, operation, [], fun)

  @doc """
  Runs `fun` as the step `operation`. Options: `:needs`, a list of
  `{label, earlier_result}` (the step is skipped unless every result is
  `{:ok, _}`), and `:note`.
  """
  @spec step(t(), String.t(), keyword(), (-> term())) :: term()
  def step(%__MODULE__{live?: false} = flow, operation, _opts, _fun) do
    skip(flow, operation, @no_key)
  end

  def step(flow, operation, opts, fun) do
    case unmet(Keyword.get(opts, :needs, [])) do
      nil -> run(flow, operation, Keyword.get(opts, :note), fun)
      reason -> skip(flow, operation, reason)
    end
  end

  defp unmet(needs) do
    Enum.find_value(needs, fn
      {_label, {:ok, _value}} -> nil
      {label, _result} -> "depends on #{label}"
    end)
  end

  defp skip(flow, operation, reason) do
    record(flow, operation, :skipped, 0, %{note: reason})
    {:skip, reason}
  end

  defp run(flow, operation, note, fun) do
    started = System.monotonic_time(:millisecond)

    outcome =
      try do
        fun.()
      rescue
        exception -> {:error, {:exception, exception}}
      end

    ms = System.monotonic_time(:millisecond) - started
    settle(flow, operation, note, ms, outcome)
  end

  defp settle(flow, operation, note, ms, {:ok, value} = outcome) do
    extra = contract_check(flow, operation, value)
    status = if Map.get(extra, :drift) in [nil, []], do: :ok, else: :failed
    record(flow, operation, status, ms, Map.put(extra, :note, note))
    outcome
  end

  defp settle(flow, operation, note, ms, {:recorded_error, error}) do
    record(flow, operation, :ok, ms, %{error: error_info(error), note: note})
    {:ok, error}
  end

  defp settle(flow, operation, _note, ms, {:skip, reason} = outcome) do
    record(flow, operation, :skipped, ms, %{note: reason})
    outcome
  end

  defp settle(flow, operation, note, ms, {:error, error} = outcome) do
    record(flow, operation, :failed, ms, %{error: error_info(error), note: note})
    outcome
  end

  defp contract_check(flow, operation, value) do
    with name when is_binary(name) <- StripeLiveContract.fixture_for(operation),
         true <- is_map(value) do
      live = StripeLiveContract.target(operation, value)

      if flow.record? do
        record_fixture(flow, operation, name, live)
      else
        fixture = StripeFixtures.object(name)
        Map.put(StripeLiveContract.compare(fixture, live), :fixture, name)
      end
    else
      _other -> %{}
    end
  end

  defp record_fixture(flow, operation, name, live) do
    if StripeLiveContract.recorded_by?(operation) do
      StripeLiveReport.capture(flow.report, name, live)
      %{note: "recorded as #{name}"}
    else
      %{}
    end
  end

  defp record(flow, operation, status, ms, extra) do
    drift = Map.get(extra, :drift)

    step =
      %{
        flow: flow.name,
        operation: operation,
        status: status,
        duration_ms: ms,
        error: nil,
        drift: drift,
        new_keys: nil,
        fixture: nil,
        note: nil
      }
      |> Map.merge(Map.take(extra, [:error, :note, :new_keys, :fixture]))
      |> Map.update!(:note, &drift_note(&1, drift))

    StripeLiveReport.record(flow.report, step)
  end

  defp drift_note(note, [_first | _rest]),
    do: note || "fixture keys missing from the live response"

  defp drift_note(note, _drift), do: note

  defp error_info(%Error{} = e) do
    %{
      type: e.type,
      code: e.code,
      decline_code: e.decline_code,
      param: e.param,
      status: e.status,
      request_id: e.request_id,
      message: redact(e.message)
    }
  end

  defp error_info({:exception, exception}) do
    %{
      type: "exception",
      code: inspect(exception.__struct__),
      message: redact(Exception.message(exception))
    }
  end

  defp error_info(other), do: %{type: "other", message: redact(inspect(other))}

  defp redact(nil), do: nil
  defp redact(text), do: Regex.replace(@secret, text, "[redacted key]")

  @doc "The operations of the flow's failed steps; empty when the flow is sound."
  @spec failed_steps(t()) :: [String.t()]
  def failed_steps(flow) do
    for %{flow: name, status: :failed, operation: operation} <-
          StripeLiveReport.steps(flow.report),
        name == flow.name,
        do: operation
  end

  @doc "Remembers a created object so the suite deletes it afterwards."
  @spec track(t(), atom(), term()) :: term()
  def track(flow, kind, {:ok, %{"id" => id}} = result) do
    StripeLiveReport.track(flow.report, kind, id)
    result
  end

  def track(_flow, _kind, result), do: result

  @doc "A call to an endpoint no resource module covers."
  @spec raw(atom(), :get | :post | :delete, [String.t()], map(), keyword()) :: Client.result()
  def raw(operation, method, path, params, opts \\ []) do
    operation |> Request.new(method, path, params, opts) |> Client.run()
  end

  @doc """
  Turns an error whose message matches `pattern` into a skip, keeping Stripe's
  wording. An error that names a `param` is a fault in our request, never an
  account setting, so it stays an error.
  """
  @spec skip_if(term(), Regex.t()) :: term()
  def skip_if({:error, %Error{message: message, param: nil}} = result, pattern)
      when is_binary(message) do
    if Regex.match?(pattern, message), do: {:skip, redact(message)}, else: result
  end

  def skip_if(result, _pattern), do: result

  @doc """
  Best-effort deletion of everything the run created, newest first so a
  subscription goes before its customer, recorded as `cleanup` steps.
  """
  @spec cleanup(pid()) :: :ok
  def cleanup(report) do
    flow = %__MODULE__{report: report, name: "cleanup", live?: true}

    for {kind, id} <- StripeLiveReport.tracked(report) do
      step(flow, "#{kind} #{id}", fn -> remove(kind, id) end)
    end

    :ok
  end

  defp remove(kind, id) do
    result =
      case kind do
        :customer -> Customers.delete(id)
        :subscription -> Subscriptions.cancel(id, %{})
        :account -> Accounts.delete(id)
        :price -> raw(:deactivate_price, :post, ["prices", id], %{active: false})
        :product -> raw(:deactivate_product, :post, ["products", id], %{active: false})
      end

    case result do
      {:error, error} -> if already_gone?(error), do: {:ok, %{}}, else: result
      ok -> ok
    end
  end

  # A deleted connected account answers 403 `account_invalid`, not a 404.
  defp already_gone?(%Error{message: message} = error) do
    Error.resource_missing?(error) or Error.account_invalid?(error) or
      (is_binary(message) and message =~ ~r/already (been )?(canceled|cancelled|deleted)/i)
  end
end
