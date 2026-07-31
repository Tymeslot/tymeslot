defmodule Tymeslot.Mailer.ApiProbe do
  @moduledoc """
  Startup credential probe for the API-based mail providers.

  Each provider exposes one cheap request that proves the credentials are
  accepted and the API is reachable without sending any mail:

      | Provider | Probe                                  |
      |----------|----------------------------------------|
      | Postmark | `GET /server`                          |
      | SendGrid | `GET /v3/scopes`                       |
      | Mailgun  | `GET /v3/domains/<domain>`             |
      | AhaSend  | `GET /v2/ping`                         |

  `Tymeslot.Mailer.Providers` decides which probe belongs to which adapter;
  this module owns the HTTP details and nothing else.

  ## Reading the result

  A `401` is the only response treated as a hard credential failure. A `403`
  means the provider recognised the key but the key's scopes do not cover the
  probe endpoint, which is common for send-only keys and says nothing about
  whether mail will go out, so it passes with a warning. Anything else that is
  not a success is reported as an unexpected response.

  Probing is skipped when the application's Finch pool has not started yet, so
  a very early boot never blocks on the network.
  """

  require Logger

  @timeout_ms 5_000

  @postmark_url "https://api.postmarkapp.com/server"
  @sendgrid_url "https://api.sendgrid.com/v3/scopes"
  @mailgun_base_url "https://api.mailgun.net/v3"
  @ahasend_base_url "https://api.ahasend.com"

  @doc """
  Runs the probe identified by `tag` against `config`.

  Returns `:ok` when the credentials are accepted (or the probe could not be
  run), `{:error, message}` when the provider rejected them.
  """
  @spec run(atom(), String.t(), keyword()) :: :ok | {:error, String.t()}
  def run(:none, _label, _config), do: :ok

  def run(tag, label, config) do
    case Process.whereis(Tymeslot.Finch) do
      nil ->
        Logger.warning(
          "Mailer credential validation skipped (Finch not started). " <>
            "Structure validated; credentials will be checked on first email send.",
          provider: label
        )

        :ok

      _pid ->
        request(tag, label, config)
    end
  end

  defp request(tag, label, config) do
    {url, headers} = probe_request(tag, config)
    Logger.info("Testing mailer credentials", provider: label)

    Finch.build(:get, url, headers)
    |> Finch.request(Tymeslot.Finch, receive_timeout: @timeout_ms)
    |> interpret(label)
  rescue
    e ->
      Logger.error("✗ Mailer credential validation raised",
        provider: label,
        reason: Exception.message(e)
      )

      {:error, "#{label} credential validation error: #{Exception.message(e)}"}
  end

  defp probe_request(:postmark, config) do
    {@postmark_url,
     [{"Accept", "application/json"}, {"X-Postmark-Server-Token", config[:api_key]}]}
  end

  defp probe_request(:sendgrid, config) do
    {@sendgrid_url, json_headers([{"Authorization", "Bearer #{config[:api_key]}"}])}
  end

  defp probe_request(:mailgun, config) do
    base = config[:base_url] || @mailgun_base_url
    credentials = Base.encode64("api:#{config[:api_key]}")

    {"#{base}/domains/#{config[:domain]}",
     json_headers([{"Authorization", "Basic #{credentials}"}])}
  end

  defp probe_request(:ahasend, config) do
    base = config[:base_url] || @ahasend_base_url

    {"#{base}/v2/ping", json_headers([{"Authorization", "Bearer #{config[:api_key]}"}])}
  end

  defp json_headers(headers), do: [{"Accept", "application/json"} | headers]

  defp interpret({:ok, %{status: status}}, label) when status in 200..299 do
    Logger.info("✓ Mailer credential validation passed", provider: label)
    :ok
  end

  defp interpret({:ok, %{status: 401}}, label) do
    Logger.error("✗ Mailer credential validation failed: credentials rejected",
      provider: label,
      reason: "401 Unauthorized"
    )

    {:error, "#{label} rejected the configured credentials (401 Unauthorized)"}
  end

  defp interpret({:ok, %{status: 403}}, label) do
    Logger.warning(
      "Mailer credentials accepted, but the key lacks permission for the validation " <>
        "endpoint (403). Sending is unaffected; the key will be exercised on first " <>
        "email send.",
      provider: label
    )

    :ok
  end

  defp interpret({:ok, %{status: 404}}, label) do
    Logger.error("✗ Mailer credential validation failed: resource not found",
      provider: label,
      reason: "404 Not Found"
    )

    {:error, "#{label} returned 404 — check the configured domain or account identifier"}
  end

  defp interpret({:ok, %{status: status, body: body}}, label) do
    Logger.error("✗ Mailer credential validation failed",
      provider: label,
      status: status,
      reason: String.slice(to_string(body), 0, 200)
    )

    {:error, "#{label} returned an unexpected status: #{status}"}
  end

  defp interpret({:error, %{reason: :timeout}}, label) do
    Logger.error("✗ Mailer credential validation timed out", provider: label)
    {:error, "Timeout connecting to #{label} (check network connectivity)"}
  end

  defp interpret({:error, reason}, label) do
    Logger.error("✗ Mailer credential validation failed",
      provider: label,
      reason: inspect(reason)
    )

    {:error, "Cannot connect to #{label}: #{inspect(reason)}"}
  end
end
