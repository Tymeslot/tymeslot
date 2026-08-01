defmodule TymeslotWeb.Helpers.IntegrationProviders do
  @moduledoc """
  Presentation helpers for integration providers — formatting messages,
  mapping errors to form fields, and rendering token expiry.

  For provider metadata (names, icons, OAuth status, listings), use
  `Tymeslot.Integrations.Providers.Directory` directly.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  @doc """
  Format token expiry for display.
  """
  @spec format_token_expiry(nil | DateTime.t()) :: String.t()
  def format_token_expiry(nil), do: dgettext("dashboard_integrations", "Unknown")

  def format_token_expiry(expires_at) do
    case DateTime.compare(expires_at, DateTime.utc_now()) do
      :gt ->
        dgettext("dashboard_integrations", "in %{duration}", duration: relative_time(expires_at))

      _other ->
        dgettext("dashboard_integrations", "Token expired")
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
    do:
      dgettext(
        "dashboard_integrations",
        "Connection test could not be attributed to your account. Please try again."
      )

  @doc """
  Format connection test success message for a provider.
  """
  @spec format_test_success_message(atom | String.t(), String.t()) :: String.t()
  def format_test_success_message(provider, message) do
    case to_string(provider) do
      "mirotalk" ->
        dgettext("dashboard_integrations", "✓ MiroTalk connection verified - %{message}",
          message: message
        )

      "google_meet" ->
        dgettext("dashboard_integrations", "✓ Google Meet connection verified - %{message}",
          message: message
        )

      "teams" ->
        dgettext("dashboard_integrations", "✓ Microsoft Teams connection verified - %{message}",
          message: message
        )

      "custom" ->
        dgettext("dashboard_integrations", "✓ Custom provider configured - %{message}",
          message: message
        )

      _other ->
        message
    end
  end

  @doc """
  Map a provider error reason to form field errors.

  Which field is blamed comes from the provider's own tag, never from the
  message: the message is localised, so matching English keywords back out of
  it would pick the right field in English only. Providers that can tell the
  two apart return `{tag, message}` (see
  `Tymeslot.Integrations.Video.Providers.MiroTalkProvider`); a bare string
  carries no such signal and lands on `:base_url`, which is where an
  unrecognised reason has always gone.

  A `ConnectionProbe` refusal (`{:rate_limited, _}` or `:unattributable`) is
  not a provider-specific problem, so it is never blamed on
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

  def reason_to_form_errors({:invalid_api_key, message}) when is_binary(message),
    do: %{api_key: message}

  def reason_to_form_errors({:unreachable, message}) when is_binary(message),
    do: %{base_url: message}

  def reason_to_form_errors(reason) when is_binary(reason), do: %{base_url: reason}

  def reason_to_form_errors(_reason),
    do: %{base_url: dgettext("dashboard_integrations", "Connection validation failed")}

  @doc """
  Turns a connection-test failure into flash-ready text.

  The counterpart to `reason_to_form_errors/1` for surfaces that show one
  message rather than field errors: a tagged reason renders its message and
  drops the tag, a bare string renders as-is, and anything else falls back to
  an inspected reason so a new shape is still legible.
  """
  @spec connection_test_error_message(term()) :: String.t()
  def connection_test_error_message({_tag, message}) when is_binary(message), do: message

  def connection_test_error_message(reason) when is_binary(reason), do: reason

  def connection_test_error_message(reason),
    do:
      dgettext("dashboard_integrations", "Connection test failed: %{reason}",
        reason: inspect(reason)
      )

  # --- internal helpers ---

  @spec relative_time(DateTime.t()) :: String.t()
  defp relative_time(datetime) do
    diff = DateTime.diff(datetime, DateTime.utc_now(), :second)

    cond do
      diff > 86_400 ->
        dngettext(
          "dashboard_integrations",
          "%{count} day",
          "%{count} days",
          div(diff, 86_400)
        )

      diff > 3600 ->
        dngettext(
          "dashboard_integrations",
          "%{count} hour",
          "%{count} hours",
          div(diff, 3600)
        )

      diff > 60 ->
        dngettext(
          "dashboard_integrations",
          "%{count} minute",
          "%{count} minutes",
          div(diff, 60)
        )

      true ->
        dngettext(
          "dashboard_integrations",
          "%{count} second",
          "%{count} seconds",
          diff
        )
    end
  end
end
