defmodule TymeslotWeb.ZoomDeauthController do
  @moduledoc """
  Receives Zoom's app deauthorization webhook.

  When a user uninstalls the Tymeslot app from their Zoom account, Zoom POSTs
  here. We verify the request signature against the Marketplace Secret Token,
  then strip every Tymeslot integration referencing that Zoom account so the
  stale OAuth tokens are removed promptly — Zoom requires this for production
  app approval.

  The same endpoint also handles Zoom's one-off `endpoint.url_validation`
  challenge, which is how the Marketplace verifies the URL is reachable and
  the configured Secret Token is correct.
  """

  use TymeslotWeb, :controller

  require Logger

  alias Plug.Conn
  alias Plug.Crypto
  alias Tymeslot.Integrations.Shared.ZoomConfig
  alias Tymeslot.Integrations.Video
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Helpers.ClientIP

  @signature_header "x-zm-signature"
  @timestamp_header "x-zm-request-timestamp"

  @spec deauthorize(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def deauthorize(conn, params) do
    with :ok <- RateLimiter.check_webhook_rate_limit(ClientIP.get(conn)),
         {:ok, secret} <- ZoomConfig.fetch_deauth_secret(),
         {:ok, raw_body} <- fetch_raw_body(conn),
         :ok <- verify_signature(conn, raw_body, secret) do
      handle_event(conn, params, secret)
    else
      {:error, :rate_limited} ->
        Logger.warning("Zoom deauth webhook rate limited", client_ip: ClientIP.get(conn))
        send_json(conn, 429, %{error: "rate_limited"})

      {:error, :missing_deauth_secret} ->
        Logger.error("Zoom deauth webhook called but ZOOM_DEAUTH_SECRET is not configured")
        send_json(conn, 500, %{error: "not_configured"})

      {:error, :missing_body} ->
        Logger.warning("Zoom deauth webhook missing raw body — webhook_paths config?")
        send_json(conn, 400, %{error: "bad_request"})

      {:error, :invalid_signature} ->
        Logger.warning("Zoom deauth webhook signature invalid")
        send_json(conn, 401, %{error: "invalid_signature"})
    end
  end

  defp handle_event(
         conn,
         %{"event" => "endpoint.url_validation", "payload" => %{"plainToken" => plain_token}},
         secret
       )
       when is_binary(plain_token) do
    encrypted_token =
      :hmac
      |> :crypto.mac(:sha256, secret, plain_token)
      |> Base.encode16(case: :lower)

    Logger.info("Zoom URL validation challenge handled")
    send_json(conn, 200, %{plainToken: plain_token, encryptedToken: encrypted_token})
  end

  defp handle_event(
         conn,
         %{"event" => "app_deauthorized", "payload" => %{"user_id" => zoom_user_id} = payload},
         _secret
       )
       when is_binary(zoom_user_id) and zoom_user_id != "" do
    if client_id_matches?(payload["client_id"]) do
      remove_integrations(zoom_user_id)
    else
      Logger.warning("Zoom deauth event client_id mismatch — ignoring",
        received_client_id: inspect(payload["client_id"])
      )
    end

    send_json(conn, 200, %{status: "ok"})
  end

  defp handle_event(conn, params, _secret) do
    Logger.info("Zoom webhook received unsupported event", event: Map.get(params, "event"))
    send_json(conn, 200, %{status: "ignored"})
  end

  defp remove_integrations(zoom_user_id) do
    {:ok, count} = Video.disconnect_by_provider_account("zoom", zoom_user_id)

    Logger.info("Zoom deauth processed",
      zoom_user_id: zoom_user_id,
      integrations_removed: count
    )
  end

  defp client_id_matches?(received) when is_binary(received) and received != "" do
    case ZoomConfig.fetch_client_id() do
      {:ok, expected} -> Crypto.secure_compare(received, expected)
      _missing -> false
    end
  end

  defp client_id_matches?(_other), do: false

  defp verify_signature(conn, raw_body, secret) do
    with [signature] <- Conn.get_req_header(conn, @signature_header),
         [timestamp] <- Conn.get_req_header(conn, @timestamp_header) do
      expected =
        "v0=" <>
          (:hmac
           |> :crypto.mac(:sha256, secret, "v0:" <> timestamp <> ":" <> raw_body)
           |> Base.encode16(case: :lower))

      if Crypto.secure_compare(signature, expected),
        do: :ok,
        else: {:error, :invalid_signature}
    else
      _missing -> {:error, :invalid_signature}
    end
  end

  defp fetch_raw_body(conn) do
    case conn.assigns[:raw_body] do
      body when is_binary(body) and body != "" -> {:ok, body}
      _missing -> {:error, :missing_body}
    end
  end

  defp send_json(conn, status, payload) do
    conn
    |> put_status(status)
    |> json(payload)
  end
end
