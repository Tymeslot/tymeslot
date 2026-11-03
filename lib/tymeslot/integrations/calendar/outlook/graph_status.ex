defmodule Tymeslot.Integrations.Calendar.Outlook.GraphStatus do
  @moduledoc """
  The Graph answers `Outlook.CalendarAPI` classifies apart from the shared
  response envelope (`Shared.ApiResponse`): a 403 carrying its
  classification in `error.code`. A throttling 403 may carry a `Retry-After`
  the caller should honour, as a 429 does. One that is neither throttling nor
  a permission failure is `:refused`, as any other 4xx refusal is in the
  shared envelope.
  """

  alias Tymeslot.Integrations.Shared.ApiResponse

  @doc """
  The error a Graph `response` stands for, or `:default` when the shared
  envelope classifies it. Passed to `ApiResponse.handle/3` as `:custom`.
  """
  @spec classify(term()) :: {:error, atom(), String.t()} | :default
  def classify({:ok, %{status: 403, body: body} = resp}) do
    ApiResponse.with_error_object(body, fn msg, decoded ->
      code = String.downcase(to_string(get_in(decoded, ["error", "code"]) || ""))
      handle_403_reason(classify_outlook_403(msg, code), msg, resp)
    end)
  end

  def classify(_response), do: :default

  defp classify_outlook_403(msg, code) do
    m = msg |> to_string() |> String.downcase()
    c = code |> to_string() |> String.downcase()

    cond do
      throttled_or_quota?(m, c) -> :rate_limited
      permission_denied?(m, c) -> :unauthorized
      true -> :refused
    end
  end

  defp throttled_or_quota?(message, code) do
    String.contains?(code, ["throttled", "quota", "limitexceeded", "limitreached"]) or
      String.contains?(message, "throttle") or
      String.contains?(message, "rate") or
      String.contains?(message, "quota")
  end

  defp permission_denied?(message, code) do
    String.contains?(code, "accessdenied") or
      String.contains?(code, "permission") or
      String.contains?(message, "permission") or
      String.contains?(message, "insufficient")
  end

  defp handle_403_reason(:rate_limited, msg, resp),
    do: {:error, :rate_limited, ApiResponse.rate_limited_message(resp, msg)}

  defp handle_403_reason(:unauthorized, msg, _resp), do: {:error, :unauthorized, msg}
  defp handle_403_reason(:refused, msg, _resp), do: {:error, :refused, msg}
end
