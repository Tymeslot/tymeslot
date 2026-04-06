defmodule TymeslotWeb.Helpers.IntegrationProviders do
  @moduledoc """
  Presentation helpers for integration providers — formatting messages,
  mapping errors to form fields, and rendering token expiry.

  For provider metadata (names, icons, OAuth status, listings), use
  `Tymeslot.Integrations.Providers.Directory` directly.
  """

  @doc """
  Format token expiry for display.
  """
  @spec format_token_expiry(nil | DateTime.t()) :: String.t()
  def format_token_expiry(nil), do: "Unknown"

  def format_token_expiry(expires_at) do
    case DateTime.compare(expires_at, DateTime.utc_now()) do
      :gt -> "in #{relative_time(expires_at)}"
      _other -> "expired"
    end
  end

  @doc """
  Format connection test success message for a provider.
  """
  @spec format_test_success_message(atom | String.t(), String.t()) :: String.t()
  def format_test_success_message(provider, message) do
    case to_string(provider) do
      "mirotalk" -> "✓ MiroTalk connection verified - #{message}"
      "google_meet" -> "✓ Google Meet connection verified - #{message}"
      "teams" -> "✓ Microsoft Teams connection verified - #{message}"
      "custom" -> "✓ Custom provider configured - #{message}"
      _other -> message
    end
  end

  @doc """
  Map a provider error reason to form field errors.
  """
  @spec reason_to_form_errors(String.t() | any()) :: map()
  def reason_to_form_errors(reason) do
    reason_down = if is_binary(reason), do: String.downcase(reason), else: ""

    cond do
      is_binary(reason) and
          (String.contains?(reason_down, "invalid api key") or
             String.contains?(reason_down, "authentication failed")) ->
        %{api_key: reason}

      is_binary(reason) and
          (String.contains?(reason_down, "url") or String.contains?(reason_down, "domain") or
             String.contains?(reason_down, "endpoint")) ->
        %{base_url: reason}

      is_binary(reason) ->
        %{base_url: reason}

      true ->
        %{base_url: "Connection validation failed"}
    end
  end

  # --- internal helpers ---

  @spec relative_time(DateTime.t()) :: String.t()
  defp relative_time(datetime) do
    diff = DateTime.diff(datetime, DateTime.utc_now(), :second)

    cond do
      diff > 86_400 -> "#{div(diff, 86_400)} day(s)"
      diff > 3600 -> "#{div(diff, 3600)} hour(s)"
      diff > 60 -> "#{div(diff, 60)} minute(s)"
      true -> "#{diff} second(s)"
    end
  end
end
