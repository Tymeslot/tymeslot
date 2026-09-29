defmodule Tymeslot.Integrations.Calendar.Outlook.GraphStatus do
  @moduledoc """
  The Graph answers `Outlook.CalendarAPI` classifies apart from the shared
  response envelope (`Shared.ApiResponse`): a 403 carrying its
  classification in `error.code`, and throttling reported as a bare 429.
  Both may carry a `Retry-After` the caller should honour.
  """

  alias Tymeslot.Integrations.Calendar.Shared.ApiResponse

  @doc """
  The error a Graph `response` stands for, or `:default` when the shared
  envelope classifies it. Passed to `ApiResponse.handle/3` as `:custom`.
  """
  @spec classify(term()) :: {:error, atom(), String.t()} | :default
  def classify({:ok, %{status: 403, body: body} = resp}) do
    ApiResponse.with_error_object(body, fn msg, decoded ->
      code = String.downcase(to_string(get_in(decoded, ["error", "code"]) || ""))
      handle_403_reason(classify_outlook_403(msg, code), msg, parse_retry_after(resp))
    end)
  end

  def classify({:ok, %{status: 429} = resp}) do
    case parse_retry_after(resp) do
      retry_after when is_integer(retry_after) ->
        {:error, :rate_limited, "retry_after:" <> Integer.to_string(retry_after)}

      nil ->
        {:error, :rate_limited, "Too many requests"}
    end
  end

  def classify(_response), do: :default

  defp classify_outlook_403(msg, code) do
    m = msg |> to_string() |> String.downcase()
    c = code |> to_string() |> String.downcase()

    cond do
      throttled_or_quota?(m, c) -> :rate_limited
      permission_denied?(m, c) -> :unauthorized
      true -> :network_error
    end
  end

  defp throttled_or_quota?(message, code) do
    String.contains?(code, "throttled") or
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

  defp parse_retry_after(resp) do
    headers = Map.get(resp, :headers, %{})

    case Map.get(headers, "retry-after") do
      [value | _rest] ->
        case Integer.parse(value) do
          {n, _remainder} -> n
          _parse_error -> nil
        end

      _no_header ->
        nil
    end
  end

  defp handle_403_reason(:rate_limited, _msg, retry_after) when is_integer(retry_after) do
    {:error, :rate_limited, "retry_after:" <> Integer.to_string(retry_after)}
  end

  defp handle_403_reason(:rate_limited, msg, _retry_after), do: {:error, :rate_limited, msg}
  defp handle_403_reason(:unauthorized, msg, _retry_after), do: {:error, :unauthorized, msg}
  defp handle_403_reason(_other_reason, msg, _retry_after), do: {:error, :network_error, msg}
end
