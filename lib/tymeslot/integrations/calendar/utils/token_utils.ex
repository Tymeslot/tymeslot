defmodule Tymeslot.Integrations.Calendar.TokenUtils do
  @moduledoc """
  Utility functions for managing OAuth tokens across calendar providers.
  Handles token expiry calculations, formatting, and status checks.
  """

  @doc """
  Formats token expiry information for display.
  Returns a tuple with status and human-readable message.
  """
  @spec format_token_expiry(map() | nil) ::
          {:no_expiry | :expired | :valid | :unknown, String.t()}
  def format_token_expiry(integration) do
    case integration do
      %{token_expires_at: nil} ->
        {:no_expiry, "No expiry"}

      %{token_expires_at: expires_at} ->
        case DateTime.compare(expires_at, DateTime.utc_now()) do
          :lt ->
            {:expired, "Expired #{relative_time(expires_at)}"}

          _ ->
            {:valid, "Expires #{relative_time(expires_at)}"}
        end

      _ ->
        {:unknown, "Unknown"}
    end
  end

  @doc """
  Checks if a token is expired.
  """
  @spec token_expired?(map() | nil) :: boolean()
  def token_expired?(nil), do: true
  def token_expired?(%{token_expires_at: nil}), do: false

  def token_expired?(%{token_expires_at: expires_at}) do
    DateTime.compare(expires_at, DateTime.utc_now()) == :lt
  end

  @doc """
  Returns the status of a token as an atom.
  """
  @spec token_status(map()) :: :expired | :valid | :no_expiry | :unknown
  def token_status(integration) do
    case format_token_expiry(integration) do
      {:expired, _} -> :expired
      {:valid, _} -> :valid
      {:no_expiry, _} -> :no_expiry
      {:unknown, _} -> :unknown
    end
  end

  @doc """
  Converts a DateTime to a human-readable relative time string.
  """
  @spec relative_time(DateTime.t()) :: String.t()
  def relative_time(datetime) do
    now = DateTime.utc_now()
    diff_seconds = DateTime.diff(datetime, now)
    abs_diff = abs(diff_seconds)

    format_relative_time(abs_diff, diff_seconds)
  end

  defp format_relative_time(abs_diff, _diff_seconds) when abs_diff < 60 do
    "just now"
  end

  defp format_relative_time(abs_diff, diff_seconds) when abs_diff < 3600 do
    format_time_unit(abs_diff, diff_seconds, 60, "minute")
  end

  defp format_relative_time(abs_diff, diff_seconds) when abs_diff < 86_400 do
    format_time_unit(abs_diff, diff_seconds, 3600, "hour")
  end

  defp format_relative_time(abs_diff, diff_seconds) when abs_diff < 2_592_000 do
    format_time_unit(abs_diff, diff_seconds, 86_400, "day")
  end

  defp format_relative_time(abs_diff, diff_seconds) do
    format_time_unit(abs_diff, diff_seconds, 2_592_000, "month")
  end

  defp format_time_unit(abs_diff, diff_seconds, divisor, unit_name) do
    count = div(abs_diff, divisor)
    unit = if count == 1, do: unit_name, else: "#{unit_name}s"

    if diff_seconds > 0 do
      "in #{count} #{unit}"
    else
      "#{count} #{unit} ago"
    end
  end

  @doc """
  Checks if a token needs to be refreshed soon.
  Returns true if token expires within the specified minutes (default 5).
  """
  @spec needs_refresh?(map(), non_neg_integer()) :: boolean()
  def needs_refresh?(integration, minutes \\ 5)
  def needs_refresh?(%{token_expires_at: nil}, _minutes), do: false

  def needs_refresh?(%{token_expires_at: expires_at}, minutes) do
    threshold = DateTime.add(DateTime.utc_now(), minutes * 60, :second)
    DateTime.compare(expires_at, threshold) == :lt
  end
end
