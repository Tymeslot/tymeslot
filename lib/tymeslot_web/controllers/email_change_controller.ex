defmodule TymeslotWeb.EmailChangeController do
  @moduledoc """
  Controller for handling email change verification links.
  """
  use TymeslotWeb, :controller
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Auth
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.EmailLinkConfirmHTML
  alias TymeslotWeb.Helpers.ClientIP

  require Logger

  @doc """
  Landing page for the emailed email-change link. Renders a confirmation
  button only: opening the link must not consume the token, or a mail scanner
  prefetching it would complete the change on the user's behalf.
  """
  @spec confirm(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def confirm(conn, %{"token" => token}) do
    conn
    |> put_layout(html: false)
    |> put_view(html: EmailLinkConfirmHTML)
    |> render(:confirm,
      action: ~p"/email-change/#{token}",
      icon: "hero-at-symbol",
      title: dgettext("auth", "Confirm your new email address"),
      body:
        dgettext("auth", "Press the button below to switch your account to this email address."),
      button: dgettext("auth", "Confirm email change")
    )
  end

  @doc """
  Verifies an email change token and completes the email change process.
  """
  @spec verify(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def verify(conn, %{"token" => token}) do
    ip = ClientIP.get(conn)

    case RateLimiter.check_email_change_verify_rate_limit(ip) do
      :ok ->
        handle_verify_result(conn, token, Auth.verify_email_change(token))

      {:error, :rate_limited, message} ->
        conn
        |> put_flash(:error, message)
        |> redirect(to: ~p"/auth/login")
    end
  end

  defp handle_verify_result(conn, token, {:ok, _user, message}) do
    Logger.info("Email change verified successfully via link", token: redact_token(token))

    conn
    |> put_flash(:info, message)
    |> redirect(to: ~p"/auth/login")
  end

  defp handle_verify_result(conn, token, {:error, {:invalid_token, message}}) do
    Logger.warning("Invalid email change token attempted", token: redact_token(token))

    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/auth/login")
  end

  defp handle_verify_result(conn, token, {:error, {:token_expired, message}}) do
    Logger.warning("Expired email change token attempted", token: redact_token(token))

    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/auth/login")
  end

  defp handle_verify_result(conn, token, {:error, {_other, message}}) do
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
