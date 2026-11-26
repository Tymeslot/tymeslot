defmodule Tymeslot.Integrations.Stripe.Error do
  @moduledoc """
  A failed Stripe call, as every resource function in
  `Tymeslot.Integrations.Stripe` returns it.

  `type` is Stripe's `error.type` as sent (`"invalid_request_error"`,
  `"card_error"`, `"api_error"`, `"idempotency_error"`), or
  `"api_connection_error"` when no response arrived, in which case `status` is
  `nil` and `reason` holds the transport reason. A response whose body is not a
  Stripe error object (an HTML page from a proxy, an empty body) is an
  `"api_error"` with `message: nil`.

  Nothing in the struct comes from a request: no key, no header, no body. A key
  Stripe quotes back in its message (it does so, masked, for an invalid key) is
  redacted when the error is built.
  """

  defexception [
    :type,
    :code,
    :decline_code,
    :param,
    :message,
    :status,
    :request_id,
    :reason,
    :operation
  ]

  @type t :: %__MODULE__{
          type: String.t(),
          code: String.t() | nil,
          decline_code: String.t() | nil,
          param: String.t() | nil,
          message: String.t() | nil,
          status: integer() | nil,
          request_id: String.t() | nil,
          reason: term(),
          operation: atom()
        }

  @key_pattern ~r/\b(?:sk|rk|pk)_(?:live|test)_[A-Za-z0-9*]*/

  @doc """
  Builds the error for a non-2xx response from its status, headers and raw body.
  """
  @spec from_response(integer(), [{String.t(), String.t()}], binary(), atom()) :: t()
  def from_response(status, headers, body, operation) do
    fields =
      case Jason.decode(body) do
        {:ok, %{"error" => %{} = error}} ->
          [
            type: error["type"] || "api_error",
            code: error["code"],
            decline_code: error["decline_code"],
            param: error["param"],
            message: redact(error["message"])
          ]

        _not_a_stripe_error ->
          [type: "api_error"]
      end

    struct!(
      __MODULE__,
      [status: status, request_id: request_id(headers), operation: operation] ++ fields
    )
  end

  @doc """
  Builds the error for a 2xx response whose body is not a JSON object.
  """
  @spec unexpected_body(integer(), [{String.t(), String.t()}], atom()) :: t()
  def unexpected_body(status, headers, operation) do
    %__MODULE__{
      type: "api_error",
      status: status,
      request_id: request_id(headers),
      message: "unexpected response body",
      operation: operation
    }
  end

  @doc """
  Builds the error for a call that got no response.
  """
  @spec from_transport(term(), atom()) :: t()
  def from_transport(reason, operation) do
    %__MODULE__{type: "api_connection_error", status: nil, reason: reason, operation: operation}
  end

  @doc """
  Whether the failure is transient, so the same call may succeed later: a
  connection failure, a 409 (idempotency conflict), a 429 or a 5xx. False for
  any other value.

  It does not say the request may be resent as it was. Stripe stores a POST's
  5xx under its idempotency key and replays it for 24 hours, so a caller that
  retries a POST under a fixed key (`IdempotencyKey.for_intent/3`) sends a new
  key after a 5xx, as `Tymeslot.MeetingPayments.RefundOutcome` does. Stripe's
  `stripe-should-retry` header is not read here; `RetryPolicy` honours it
  within one call.
  """
  @spec retryable?(term()) :: boolean()
  def retryable?(%__MODULE__{type: "api_connection_error"}), do: true
  def retryable?(%__MODULE__{status: status}) when status in [409, 429], do: true
  def retryable?(%__MODULE__{status: status}) when is_integer(status) and status >= 500, do: true
  def retryable?(_other), do: false

  @doc """
  Whether the error says the object does not exist: code `resource_missing` or
  status 404. False for any other value.
  """
  @spec resource_missing?(term()) :: boolean()
  def resource_missing?(%__MODULE__{code: "resource_missing"}), do: true
  def resource_missing?(%__MODULE__{status: 404}), do: true
  def resource_missing?(_other), do: false

  @doc """
  Whether Stripe refused a call made on a connected account's behalf because
  the platform has no access to that account: code `account_invalid`, which
  Stripe sends once the account is deleted or has revoked the platform's
  access. False for any other value, including a 403 with another code (a
  restricted key lacking a permission, say).
  """
  @spec account_invalid?(term()) :: boolean()
  def account_invalid?(%__MODULE__{code: "account_invalid"}), do: true
  def account_invalid?(_other), do: false

  @doc """
  `"Stripe <operation> failed: <type> (HTTP <status>, request <request_id>): <message>"`,
  leaving out the parts the error lacks. A transport failure ends with its reason
  when that is an atom.
  """
  @impl Exception
  @spec message(t()) :: String.t()
  def message(%__MODULE__{} = error) do
    "Stripe #{error.operation} failed: #{error.type}" <> details(error) <> detail_text(error)
  end

  defp details(error) do
    case Enum.reject(
           [
             error.status && "HTTP #{error.status}",
             error.request_id && "request #{error.request_id}"
           ],
           &is_nil/1
         ) do
      [] -> ""
      parts -> " (" <> Enum.join(parts, ", ") <> ")"
    end
  end

  defp detail_text(%__MODULE__{message: message}) when is_binary(message), do: ": " <> message

  defp detail_text(%__MODULE__{reason: reason}) when is_atom(reason) and not is_nil(reason),
    do: ": " <> Atom.to_string(reason)

  defp detail_text(_error), do: ""

  @doc "The `request-id` header Stripe sets on a response, or `nil`."
  @spec request_id([{String.t(), String.t()}]) :: String.t() | nil
  def request_id(headers) do
    Enum.find_value(headers, fn {name, value} -> name == "request-id" && value end)
  end

  defp redact(message) when is_binary(message),
    do: Regex.replace(@key_pattern, message, "[redacted key]")

  defp redact(_message), do: nil
end
