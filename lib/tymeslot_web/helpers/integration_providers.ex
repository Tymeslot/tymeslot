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
  Turns a `Tymeslot.Integrations.Shared.ConnectionProbe` refusal into a
  flash-ready message.

  `{:rate_limited, message}` carries the limiter's own user-facing text
  verbatim; `:unattributable` gets a fixed message here, since
  `ConnectionProbe` deliberately never invents user-facing copy for it (see
  its moduledoc) — building that copy is the web layer's job.
  """
  @spec connection_test_refusal_message({:rate_limited, String.t()} | :unattributable) ::
          String.t()
  def connection_test_refusal_message({:rate_limited, message}), do: message

  def connection_test_refusal_message(:unattributable),
    do: "Connection test could not be attributed to your account. Please try again."

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

  A `ConnectionProbe` refusal (`{:rate_limited, _}` or `:unattributable`) is
  not a provider-specific problem, so it is never classified against
  `:api_key`/`:base_url` — it lands on `:base`, using
  `connection_test_refusal_message/1` for the copy, the one place that text
  is built.
  """
  @spec reason_to_form_errors({:rate_limited, String.t()} | :unattributable | String.t() | any()) ::
          map()
  def reason_to_form_errors({:rate_limited, _message} = refusal),
    do: %{base: connection_test_refusal_message(refusal)}

  def reason_to_form_errors(:unattributable),
    do: %{base: connection_test_refusal_message(:unattributable)}

  def reason_to_form_errors(reason) do
    case classify_reason(reason) do
      :api_key -> %{api_key: reason}
      :base_url -> %{base_url: reason}
      :non_binary -> %{base_url: "Connection validation failed"}
    end
  end

  defp classify_reason(reason) when is_binary(reason) do
    r = String.downcase(reason)

    if String.contains?(r, "invalid api key") or String.contains?(r, "authentication failed") do
      :api_key
    else
      :base_url
    end
  end

  defp classify_reason(_reason), do: :non_binary

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
