defmodule Tymeslot.Integrations.Calendar.TokenRefreshJob do
  @moduledoc """
  Background job for refreshing calendar OAuth tokens with intelligent retry strategy.

  This job runs periodically to refresh OAuth tokens that are about to expire,
  ensuring continuous access to calendar APIs for both Google and Outlook.

  Uses custom exponential backoff optimized for token refresh timing:
  - Fast initial retries for transient issues
  - Longer backoffs to avoid rate limiting
  - Takes advantage of 2-hour refresh buffer
  """

  use Oban.Worker,
    queue: :calendar_integrations,
    max_attempts: 8

  require Logger

  alias Tymeslot.DatabaseQueries.CalendarIntegrationQueries
  alias Tymeslot.DatabaseSchemas.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Tokens
  alias Tymeslot.Integrations.Common.ErrorHandler

  @refresh_threshold_hours 2

  @doc """
  Custom backoff strategy optimized for token refresh.

  Since we start refreshing 2 hours before expiration, we can afford
  longer backoffs to avoid rate limiting while still having plenty of buffer time.
  """
  @spec custom_backoff(non_neg_integer()) :: non_neg_integer()
  def custom_backoff(attempt) do
    case attempt do
      # 1 second (network hiccup)
      1 -> 1
      # 3 seconds (quick retry)
      2 -> 3
      # 10 seconds (maybe temporary issue)
      3 -> 10
      # 5 minutes (avoid rate limits)
      4 -> 300
      # 15 minutes (longer cooldown)
      5 -> 900
      # 30 minutes (significant backoff)
      6 -> 1800
      # 1 hour (final attempt)
      7 -> 3600
      # Cap at 1 hour
      _ -> 3600
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"integration_id" => integration_id}}) do
    # Single integration refresh (for retry jobs)
    case CalendarIntegrationQueries.get(integration_id) do
      {:error, :not_found} ->
        {:discard, "Integration not found"}

      {:ok, integration} ->
        refresh_integration_token(integration)
    end
  end

  def perform(%Oban.Job{}) do
    # Bulk refresh for periodic job
    refresh_expiring_tokens()
  end

  @doc """
  Refreshes all calendar tokens that are expiring soon for both Google and Outlook.
  """
  @spec refresh_expiring_tokens() :: :ok | {:error, term()}
  def refresh_expiring_tokens do
    threshold = DateTime.add(DateTime.utc_now(), @refresh_threshold_hours, :hour)

    # Refresh Google Calendar tokens
    Enum.each(
      CalendarIntegrationQueries.list_expiring_google_tokens(threshold),
      &schedule_individual_refresh/1
    )

    # Refresh Outlook Calendar tokens
    Enum.each(
      CalendarIntegrationQueries.list_expiring_outlook_tokens(threshold),
      &schedule_individual_refresh/1
    )

    :ok
  end

  defp schedule_individual_refresh(%CalendarIntegrationSchema{id: id}) do
    %{"integration_id" => id}
    |> new()
    |> Oban.insert()
  end

  @doc """
  Schedules the token refresh job to run every hour.
  """
  @spec schedule_periodic_refresh() :: Oban.Job.t()
  def schedule_periodic_refresh do
    %{}
    |> new(schedule_in: 3600)
    |> Oban.insert!()
  end

  # Private functions

  defp refresh_integration_token(%CalendarIntegrationSchema{provider: provider} = integration) do
    # Use the centralized Tokens.refresh_oauth_token which includes single-flight locking
    result =
      ErrorHandler.handle_with_logging(
        fn -> Tokens.refresh_oauth_token(integration) end,
        operation: "refresh OAuth token",
        provider: provider,
        log_level: :warning
      )

    case result do
      {:ok, _updated_integration} ->
        # Tokens.refresh_oauth_token handles persistence already
        :ok

      {:error, :refresh_in_progress} ->
        # Another process is already refreshing this token.
        # We can just return :ok and let the other process finish,
        # or snooze if we want to be sure. Given it's a job, :ok is fine.
        Logger.info("Token refresh skipped: already in progress",
          integration_id: integration.id,
          provider: provider
        )

        :ok

      {:error, {type, msg}} ->
        handle_refresh_error(integration, "#{type}: #{msg}", provider)

      {:error, reason} ->
        handle_refresh_error(integration, reason, provider)
    end
  end

  defp handle_refresh_error(integration, reason, provider) do
    case categorize_error(reason) do
      :permanent ->
        # Don't retry - mark for re-authorization
        error_msg =
          ErrorHandler.format_integration_error(
            provider,
            "token refresh",
            "#{reason} (PERMANENT)"
          )

        CalendarIntegrationQueries.update_integration(integration, %{
          sync_error: error_msg,
          is_active: false
        })

        {:discard, "Permanent error: #{reason}"}

      :rate_limited ->
        # Respect rate limiting with custom backoff
        retry_after = extract_retry_after(reason)

        error_msg =
          ErrorHandler.format_integration_error(
            provider,
            "token refresh",
            "#{reason} (RATE_LIMITED)"
          )

        CalendarIntegrationQueries.update_integration(integration, %{sync_error: error_msg})
        {:snooze, retry_after}

      :retryable ->
        # Let Oban handle retry with our custom backoff
        error_msg =
          ErrorHandler.format_integration_error(
            provider,
            "token refresh",
            "#{reason} (RETRYABLE)"
          )

        CalendarIntegrationQueries.update_integration(integration, %{sync_error: error_msg})
        {:error, "#{reason}"}
    end
  end

  defp categorize_error(reason) when is_binary(reason) do
    reason_lower = String.downcase(reason)

    cond do
      permanent_error?(reason_lower) -> :permanent
      rate_limited_error?(reason_lower) -> :rate_limited
      retryable_error?(reason_lower) -> :retryable
      true -> :retryable
    end
  end

  defp categorize_error(_reason), do: :retryable

  defp permanent_error?(reason_lower) do
    permanent_errors = ["invalid_grant", "unauthorized", "invalid_client", "access_denied"]
    Enum.any?(permanent_errors, &String.contains?(reason_lower, &1))
  end

  defp rate_limited_error?(reason_lower) do
    rate_limit_errors = ["rate_limited", "too_many_requests", "quota"]
    Enum.any?(rate_limit_errors, &String.contains?(reason_lower, &1))
  end

  defp retryable_error?(reason_lower) do
    retryable_errors = ["network", "timeout", "connection", "dns", "ssl"]
    Enum.any?(retryable_errors, &String.contains?(reason_lower, &1))
  end

  defp extract_retry_after(reason) when is_binary(reason) do
    # Try to extract retry-after from error message
    case Regex.run(~r/retry[_\s]after[:\s]+(\d+)/i, reason) do
      [_, seconds_str] -> String.to_integer(seconds_str)
      # Default to 5 minutes if no retry-after found
      _ -> 300
    end
  end

  defp extract_retry_after(_), do: 300
end
