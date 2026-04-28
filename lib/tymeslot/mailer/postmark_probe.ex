defmodule Tymeslot.Mailer.PostmarkProbe do
  @moduledoc """
  Postmark API key probe used during mailer health checks.

  Calls Postmark's `/server` endpoint with the configured API token to
  confirm the key is valid and the API is reachable. The endpoint sends no
  email and is safe to call at startup. Skipped when the application's Finch
  pool has not yet started (e.g. very early boot).
  """

  require Logger

  @timeout_ms 5_000

  @doc """
  Tests the configured Postmark API key. Returns `:ok` on success,
  `{:error, message}` on validation failure.
  """
  @spec test_api_key(keyword()) :: :ok | {:error, String.t()}
  def test_api_key(config) do
    case Process.whereis(Tymeslot.Finch) do
      nil ->
        Logger.warning(
          "Postmark API key validation skipped (Finch not started). " <>
            "Structure validated but cannot test API connectivity. " <>
            "API key will be validated on first email send."
        )

        :ok

      _pid ->
        do_test_api_key(config)
    end
  end

  defp do_test_api_key(config) do
    api_key = config[:api_key]
    Logger.info("Testing Postmark API key...")

    url = "https://api.postmarkapp.com/server"

    headers = [
      {"Accept", "application/json"},
      {"X-Postmark-Server-Token", api_key}
    ]

    case Finch.request(Finch.build(:get, url, headers), Tymeslot.Finch,
           receive_timeout: @timeout_ms
         ) do
      {:ok, %{status: 200}} ->
        Logger.info("✓ Postmark API key validation passed")
        :ok

      {:ok, %{status: 401}} ->
        Logger.error("✗ Postmark API key validation failed: Invalid API key")
        {:error, "Invalid Postmark API key (401 Unauthorized)"}

      {:ok, %{status: 422, body: body}} ->
        Logger.error("✗ Postmark API key validation failed",
          status: 422,
          body: String.slice(body, 0, 200)
        )

        {:error, "Invalid Postmark API key format (422 Unprocessable Entity)"}

      {:ok, %{status: status}} ->
        Logger.error("✗ Postmark API validation failed", status: status)
        {:error, "Postmark API returned unexpected status: #{status}"}

      {:error, %{reason: :timeout}} ->
        Logger.error("✗ Postmark API validation timed out")
        {:error, "Timeout connecting to Postmark API (check network connectivity)"}

      {:error, reason} ->
        Logger.error("✗ Postmark API validation failed", reason: inspect(reason))
        {:error, "Cannot connect to Postmark API: #{inspect(reason)}"}
    end
  rescue
    e ->
      Logger.error("✗ Postmark API validation exception", error: Exception.message(e))
      {:error, "Postmark API validation error: #{Exception.message(e)}"}
  end
end
