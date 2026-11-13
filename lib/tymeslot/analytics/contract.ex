defmodule Tymeslot.Analytics.Contract do
  @moduledoc """
  Single source of truth for analytics events. Validation is an ALLOWLIST: an
  event must be declared, and every prop key must be declared for that event —
  so user ids/emails (never declared) can't leak. The PII denylist is a second
  guard that fails the registry test if someone tries to *declare* a bad key.

  Core declares its client-side (push) events here; SaaS declares its own
  server-side events and calls `validate_with!/3` with the shared validator.

  A prop whose values form a closed set also declares that set
  (`allowed_values/2`), and a value outside it is a violation like an
  undeclared key: `booking_link_shared`'s channels (`share_channels/0`)
  and `calendar_reveal_loaded`'s results.

  Validation raises in strict mode (dev/test) so a malformed or PII-carrying
  event is caught at the source. In prod, strict mode is off: callers receive
  `{:error, reason}` on a violation, log a warning, and drop the event rather
  than crashing a live user flow.
  """

  require Logger

  # Core client (Tier-1, pushed to the browser via TymeslotWeb.Analytics.push/3)
  # events → allowed categorical prop keys. Every entry here MUST be emitted
  # somewhere, or the completeness check fails — keep this in lockstep with the
  # code that emits.
  @registry %{
    "onboarding_step_viewed" => [:step],
    "onboarding_step_completed" => [:step],
    "calendar_reveal_loaded" => [:result],
    "booking_link_shared" => [:channel],
    "share_step_viewed" => [:page_live, :returned],
    "guest_preview_opened" => []
  }

  # The dashboard's copy points for the host's own booking link.
  @share_channels ~w(sidebar settings embed)
  @reveal_results ~w(ok slow failed)

  @pii_denylist ~w(user_id email username name token ip ip_address phone customer_id)a

  @doc "The Core event registry: event name => allowed categorical prop keys."
  @spec registry() :: %{optional(String.t()) => [atom()]}
  def registry, do: @registry

  @doc "The dashboard places a host copies their booking link from (`booking_link_shared`)."
  @spec share_channels() :: [String.t()]
  def share_channels, do: @share_channels

  @doc """
  The values `key` may take on Core event `name`, or `nil` when they are
  open (a step name, a boolean).
  """
  @spec allowed_values(String.t(), atom()) :: [String.t()] | nil
  def allowed_values("booking_link_shared", :channel), do: @share_channels
  def allowed_values("calendar_reveal_loaded", :result), do: @reveal_results
  def allowed_values(_name, _key), do: nil

  @doc "Prop keys that must never be declared on any event."
  @spec pii_denylist() :: [atom()]
  def pii_denylist, do: @pii_denylist

  @doc """
  Validate against the Core registry and its closed value sets. Always runs
  the full allowlist check. Raises in strict mode (dev/test); returns
  `{:error, reason}` in non-strict.
  """
  @spec validate!(String.t(), map()) :: :ok | {:error, term()}
  def validate!(name, props), do: validate_with!(name, props, @registry, &allowed_values/2)

  @doc """
  Generic validator other apps (SaaS) call with their own registry.

  Always validates regardless of mode. In strict mode (dev/test), raises
  `ArgumentError` when the event is unknown, a prop key is not declared for it,
  or a prop value is not a categorical scalar, or lies outside the set
  `values` (`(name, key) -> [String.t()] | nil`, open by default) declares for
  it. In non-strict mode (prod), logs a warning (event name and offending key
  names only — never prop values) and returns `{:error, reason}` so the caller
  can drop the event.
  """
  @spec validate_with!(
          String.t(),
          map(),
          %{optional(String.t()) => [atom()]},
          (String.t(), atom() -> [String.t()] | nil)
        ) :: :ok | {:error, term()}
  def validate_with!(name, props, registry, values \\ fn _name, _key -> nil end) do
    case do_validate(name, props, registry, values) do
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
  @spec do_validate(
          String.t(),
          map(),
          %{optional(String.t()) => [atom()]},
          (String.t(), atom() -> [String.t()] | nil)
        ) :: :ok | {:error, {[atom()], String.t()}}
  defp do_validate(name, _props, registry, _values) when not is_map_key(registry, name) do
    {:error, {[], "unknown analytics event: #{inspect(name)}"}}
  end

  defp do_validate(name, props, registry, values) do
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

        not allowed_value?(values.(name, key), value) ->
          {:halt,
           {:error, {[key], "event #{name}: prop #{inspect(key)} value outside its declared set"}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp allowed_value?(nil, _value), do: true
  defp allowed_value?(allowed, value), do: to_string(value) in allowed

  defp categorical?(value),
    do: is_binary(value) or is_atom(value) or is_number(value) or is_boolean(value)

  # Whether validation raises (dev/test) or logs-and-drops (prod). Set
  # `config :tymeslot, :analytics_strict, false` in prod so a contract bug logs
  # and drops rather than crashing a live user flow.
  @spec strict?() :: boolean()
  defp strict?, do: Application.get_env(:tymeslot, :analytics_strict, true)
end
