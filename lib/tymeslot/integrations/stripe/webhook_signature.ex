defmodule Tymeslot.Integrations.Stripe.WebhookSignature do
  @moduledoc """
  Verifies the `Stripe-Signature` header of a webhook delivery.

  The header carries a timestamp (`t`) and one or more `v1` signatures, each
  an HMAC-SHA256 of `"<t>.<raw body>"` keyed with the endpoint's signing
  secret. A delivery verifies when any `v1` matches and the timestamp is no
  older than the tolerance. Only the past side of the window is checked: a
  timestamp in the future verifies. Schemes other than `v1` are ignored, and
  when the timestamp is repeated the first one that parses as a whole
  integer counts (a value with trailing characters is not a timestamp).

  The module is pure: the clock is the `:now` option, so callers and tests
  decide what time it is. Verify before decoding the body.
  """

  alias Plug.Crypto

  @default_tolerance 300

  @type error :: :missing_header | :no_signatures | :timestamp_expired | :signature_mismatch

  @doc """
  Checks `header` against `raw_body` and `secret`.

  Options: `:tolerance` in seconds (default #{@default_tolerance}) and `:now`
  as Unix seconds (default the system clock).
  """
  @spec verify(binary(), binary() | nil, binary(), tolerance: pos_integer(), now: integer()) ::
          :ok | {:error, error()}
  def verify(raw_body, header, secret, opts \\ [])
      when is_binary(raw_body) and is_binary(secret) do
    tolerance = Keyword.get(opts, :tolerance, @default_tolerance)
    now = Keyword.get_lazy(opts, :now, fn -> System.system_time(:second) end)

    do_verify(raw_body, parse(header), secret, tolerance, now)
  end

  defp do_verify(_raw_body, %{timestamp: nil}, _secret, _tolerance, _now),
    do: {:error, :missing_header}

  defp do_verify(_raw_body, %{signatures: []}, _secret, _tolerance, _now),
    do: {:error, :no_signatures}

  defp do_verify(raw_body, %{timestamp: t, signatures: signatures}, secret, tolerance, now) do
    cond do
      t < now - tolerance ->
        {:error, :timestamp_expired}

      matches?(signatures, expected(raw_body, t, secret)) ->
        :ok

      true ->
        {:error, :signature_mismatch}
    end
  end

  defp expected(raw_body, timestamp, secret) do
    :hmac
    |> :crypto.mac(:sha256, secret, "#{timestamp}.#{raw_body}")
    |> Base.encode16(case: :lower)
  end

  defp matches?(signatures, expected),
    do: Enum.any?(signatures, &Crypto.secure_compare(&1, expected))

  defp parse(header) when is_binary(header) do
    pairs =
      header
      |> String.split(",")
      |> Enum.flat_map(fn part ->
        case part |> String.trim() |> String.split("=", parts: 2) do
          [key, value] -> [{key, value}]
          _malformed -> []
        end
      end)

    %{timestamp: first_timestamp(pairs), signatures: for({"v1", sig} <- pairs, do: sig)}
  end

  defp parse(_header), do: %{timestamp: nil, signatures: []}

  defp first_timestamp(pairs) do
    Enum.find_value(pairs, fn
      {"t", value} ->
        case Integer.parse(value) do
          {int, ""} -> int
          _other -> nil
        end

      _pair ->
        nil
    end)
  end
end
