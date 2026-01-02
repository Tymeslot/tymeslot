defmodule TymeslotWeb.EmailChangeController do
  @moduledoc """
  Controller for handling email change verification links.
  """
  use TymeslotWeb, :controller

  alias Tymeslot.Auth
  alias Tymeslot.Security.RateLimiter

  require Logger

  @doc """
  Verifies an email change token and completes the email change process.
  """
  @spec verify(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def verify(conn, %{"token" => token}) do
    ip = conn.remote_ip |> :inet_parse.ntoa() |> to_string()

    with :ok <- RateLimiter.check_rate_limit("email_change_verify:" <> ip, 30, 60_000),
         result <- Auth.verify_email_change(token) do
      handle_verify_result(conn, token, result)
    else
      {:error, :rate_limited} ->
        Logger.warning("Rate limit exceeded for email change verify", ip: ip)

        conn
        |> put_flash(:error, "Too many attempts. Try again in a minute.")
        |> redirect(to: ~p"/auth/login")
        |> halt()
    end
  end

  def verify(conn, _params) do
    Logger.warning("Email change verification attempted without token")

    conn
    |> put_flash(:error, "Invalid verification link")
    |> redirect(to: ~p"/auth/login")
  end

  defp handle_verify_result(conn, token, {:ok, _user, message}) do
    Logger.info("Email change verified successfully via link", token: redact_token(token))

    conn
    |> put_flash(:info, message)
    |> redirect(to: ~p"/auth/login")
  end

  defp handle_verify_result(conn, token, {:error, :invalid_token, message}) do
    Logger.warning("Invalid email change token attempted", token: redact_token(token))

    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/auth/login")
  end

  defp handle_verify_result(conn, token, {:error, :token_expired, message}) do
    Logger.warning("Expired email change token attempted", token: redact_token(token))

    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/auth/login")
  end

  defp handle_verify_result(conn, token, {:error, _other, message}) do
    Logger.error("Email change verification failed",
      token: redact_token(token),
      error: message
    )

    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/auth/login")
  end

  defp redact_token(token) when is_binary(token) do
    if String.length(token) >= 8 do
      "…" <> String.slice(token, -8, 8)
    else
      "…REDACTED"
    end
  end
end
