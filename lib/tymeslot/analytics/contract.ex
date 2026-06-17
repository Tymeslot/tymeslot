defmodule Tymeslot.Analytics.Contract do
  @moduledoc """
  Single source of truth for analytics events. Validation is an ALLOWLIST: an
  event must be declared, and every prop key must be declared for that event —
  so user ids/emails (never declared) can't leak. The PII denylist is a second
  guard that fails the registry test if someone tries to *declare* a bad key.

  Core declares its client-side (push) events here; SaaS declares its own
  server-side events and calls `validate_with!/3` with the shared validator.

  Validation raises in strict mode (dev/test) so a malformed or PII-carrying
  event is caught at the source. In prod, `strict?/0` is false: callers receive
  `{:error, reason}` on a violation, log a warning, and drop the event rather
  than crashing a live user flow.
  """

  require Logger

  # Core client (Tier-1, pushed to the browser via TymeslotWeb.Analytics.push/3)
  # events → allowed categorical prop keys. Every entry here MUST be emitted
  # somewhere, or the completeness check fails — keep this in lockstep with the
  # code that emits.
  @registry %{
    "onboarding_step_completed" => [:step, :skipped]
  }

  @pii_denylist ~w(user_id email username name token ip ip_address phone customer_id)a

  @doc "The Core event registry: event name => allowed categorical prop keys."
  @spec registry() :: %{optional(String.t()) => [atom()]}
  def registry, do: @registry

  @doc "Prop keys that must never be declared on any event."
  @spec pii_denylist() :: [atom()]
  def pii_denylist, do: @pii_denylist

  @doc """
  Validate against the Core registry. Always runs the full allowlist check.
  Raises in strict mode (dev/test); returns `{:error, reason}` in non-strict.
  """
  @spec validate!(String.t(), map()) :: :ok | {:error, term()}
  def validate!(name, props), do: validate_with!(name, props, @registry)

  @doc """
  Generic validator other apps (SaaS) call with their own registry.

  Always validates regardless of mode. In strict mode (dev/test), raises
  `ArgumentError` when the event is unknown, a prop key is not declared for it,
  or a prop value is not a categorical scalar. In non-strict mode (prod), logs a
  warning (event name and offending key names only — never prop values) and
  returns `{:error, reason}` so the caller can drop the event.
  """
  @spec validate_with!(String.t(), map(), %{optional(String.t()) => [atom()]}) ::
          :ok | {:error, term()}
  def validate_with!(name, props, registry) do
    case do_validate(name, props, registry) do
      :ok ->
        :ok

      {:error, {offending_keys, message}} = error ->
        if strict?() do
          raise ArgumentError, message
        else
          # Static message; the offending KEY names go to keyword metadata
          # (rendered by logger_json in prod). Prop VALUES are never logged.
          Logger.warning("analytics event dropped: contract violation",
            event: name,
            keys: offending_keys
          )

          error
        end
    end
  end

  # Pure validation — always runs the full allowlist check.
  # Returns :ok or {:error, {offending_keys, message}}.
  @spec do_validate(String.t(), map(), %{optional(String.t()) => [atom()]}) ::
          :ok | {:error, {[atom()], String.t()}}
  defp do_validate(name, _props, registry) when not is_map_key(registry, name) do
    {:error, {[], "unknown analytics event: #{inspect(name)}"}}
  end

  defp do_validate(name, props, registry) do
    allowed = Map.fetch!(registry, name)

    Enum.reduce_while(props, :ok, fn {key, value}, :ok ->
      cond do
        key not in allowed ->
          {:halt,
           {:error,
            {[key],
             "event #{name}: prop #{inspect(key)} not declared (allowed: #{inspect(allowed)})"}}}

        not categorical?(value) ->
          {:halt,
           {:error,
            {[key],
             "event #{name}: prop #{inspect(key)} value not categorical: #{inspect(value)}"}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp categorical?(value),
    do: is_binary(value) or is_atom(value) or is_number(value) or is_boolean(value)

  @doc """
  Whether validation raises (dev/test) or logs-and-drops (prod). Set
  `config :tymeslot, :analytics_strict, false` in prod so a contract bug logs
  and drops rather than crashing a live user flow.
  """
  @spec strict?() :: boolean()
  def strict?, do: Application.get_env(:tymeslot, :analytics_strict, true)
end
