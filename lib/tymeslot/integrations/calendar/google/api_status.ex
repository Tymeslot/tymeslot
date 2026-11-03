defmodule Tymeslot.Integrations.Calendar.Google.ApiStatus do
  @moduledoc """
  The statuses Google Calendar answers differently from the shared response
  envelope (`Shared.ApiResponse`): a 403 carrying its classification in
  `error.errors[].reason`, and a 410 marking a sync token the caller must
  discard. `Google.CalendarAPI` hands every response through `classify/1`.

  A 403 that is neither throttling nor an authorisation failure, such as a
  write to a calendar the account may only read, is `:refused`, as any other
  4xx refusal is in the shared envelope.
  """

  alias Tymeslot.Integrations.Shared.ApiResponse

  @doc """
  The error a Google response stands for, or `:default` when the shared
  envelope handles it.
  """
  @spec classify(term()) :: {:error, atom(), String.t()} | :default
  def classify({:ok, %Req.Response{status: 403, body: body}}) do
    ApiResponse.with_error_object(body, fn error_msg, decoded ->
      classify_403(error_msg, get_in(decoded, ["error", "errors"]) || [])
    end)
  end

  def classify({:ok, %Req.Response{status: 410}}) do
    {:error, :gone, "Resource no longer available"}
  end

  def classify(_response), do: :default

  defp classify_403(error_msg, reasons) do
    reason_strings =
      reasons
      |> Enum.map(&(&1["reason"] || ""))
      |> Enum.map(&String.downcase/1)

    cond do
      "notacalendaruser" in reason_strings -> {:error, :not_a_calendar_user, error_msg}
      rate_limited?(error_msg, reason_strings) -> {:error, :rate_limited, error_msg}
      unauthorized_forbidden?(error_msg, reason_strings) -> {:error, :unauthorized, error_msg}
      true -> {:error, :refused, error_msg}
    end
  end

  # Google's throttling and quota reasons (`rateLimitExceeded`,
  # `userRateLimitExceeded`, `quotaExceeded`, `dailyLimitExceeded`) and the
  # messages it sends with them ("Calendar usage limits exceeded.", "Daily
  # Limit Exceeded") all clear once the window passes, so they are retried.
  @rate_limit_reason_fragments ["ratelimit", "quotaexceeded", "limitexceeded", "usagelimits"]
  @rate_limit_message_fragments ["quota", "rate limit", "usage limits", "limit exceeded"]

  defp rate_limited?(error_msg, reason_strings) do
    msg = String.downcase(error_msg)

    Enum.any?(reason_strings, &String.contains?(&1, @rate_limit_reason_fragments)) or
      String.contains?(msg, @rate_limit_message_fragments)
  end

  defp unauthorized_forbidden?(error_msg, reason_strings) do
    msg = String.downcase(error_msg)

    String.contains?(msg, "insufficient") or
      String.contains?(msg, "forbidden") or
      Enum.any?(reason_strings, &String.contains?(&1, "insufficientpermissions"))
  end
end
