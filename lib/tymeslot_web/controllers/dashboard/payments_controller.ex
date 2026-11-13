defmodule TymeslotWeb.Dashboard.PaymentsController do
  @moduledoc """
  Controller for payments-dashboard side effects that need a full
  redirect (rather than a LiveView push_navigate): the start of the Stripe
  Connect authorisation and the callback Stripe sends the host back to.
  """

  use TymeslotWeb, :controller
  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.MeetingPayments
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Helpers.ClientIP

  @spec connect(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def connect(conn, _params) do
    user = conn.assigns.current_user

    # `start_onboarding/1` enforces the feature gate itself, so a forged POST
    # cannot start onboarding even though the UI hides the button.
    case MeetingPayments.start_onboarding(user) do
      {:ok, %{url: url}} ->
        redirect(conn, external: url)

      {:error, reason} ->
        Logger.warning("Stripe Connect onboarding could not be started",
          user_id: user.id,
          reason: LogFormat.reason(reason)
        )

        flash_error(conn, connect_error_message(reason))
    end
  end

  @spec callback(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def callback(conn, %{"error" => "access_denied"}) do
    conn
    |> put_flash(:info, dgettext("dashboard_payments", "Stripe connection cancelled."))
    |> redirect(to: ~p"/dashboard/payments")
  end

  # Neither the code, the state nor Stripe's error description is logged.
  def callback(conn, %{"error" => error}) when is_binary(error) do
    Logger.info("Stripe Connect authorisation returned an error", error: error)
    flash_error(conn, connect_error_message(:oauth_failed))
  end

  def callback(conn, %{"code" => code, "state" => state})
      when is_binary(code) and is_binary(state) do
    user = conn.assigns.current_user

    with :ok <- RateLimiter.check(:integration_oauth_callback, ClientIP.get(conn)),
         {:ok, _account} <- MeetingPayments.complete_oauth_callback(user, code, state) do
      # `return=1` makes the dashboard resync the account straight away.
      conn
      |> put_flash(:info, dgettext("dashboard_payments", "Stripe connected."))
      |> redirect(to: ~p"/dashboard/payments?return=1")
    else
      {:error, :rate_limited, _message} ->
        flash_error(
          conn,
          dgettext("dashboard_payments", "Too many requests. Please try again later.")
        )

      {:error, reason} ->
        Logger.warning("Stripe Connect callback failed",
          user_id: user.id,
          reason: LogFormat.reason(reason)
        )

        flash_error(conn, callback_error_message(reason))
    end
  end

  def callback(conn, _params), do: flash_error(conn, connect_error_message(:invalid_state))

  defp flash_error(conn, message) do
    conn
    |> put_flash(:error, message)
    |> redirect(to: ~p"/dashboard/payments")
  end

  defp error_message(:feature_disabled),
    do: dgettext("dashboard_payments", "Meeting payments are not enabled for this account.")

  defp error_message(plan_error) when plan_error in [:pro_required, :insufficient_plan],
    do: dgettext("dashboard_payments", "Meeting payments require an upgraded plan.")

  defp error_message(:oauth_not_configured),
    do:
      dgettext(
        "dashboard_payments",
        "Stripe payments are not fully set up on this server. Please contact the administrator."
      )

  defp error_message(:already_connected),
    do: dgettext("dashboard_payments", "A Stripe account is already connected.")

  defp error_message(reason)
       when reason in [:invalid_state, :user_mismatch, :expired_state, :state_already_used],
       do:
         dgettext(
           "dashboard_payments",
           "That Stripe connection link is no longer valid. Please try again."
         )

  defp error_message(reason) when reason in [:invalid_grant, :oauth_failed],
    do:
      dgettext(
        "dashboard_payments",
        "Stripe could not complete the connection. Please try again."
      )

  defp error_message(:account_already_linked),
    do:
      dgettext(
        "dashboard_payments",
        "That Stripe account is already connected to another Tymeslot account."
      )

  defp error_message(:unsupported_currency),
    do:
      dgettext(
        "dashboard_payments",
        "That Stripe account uses a currency Tymeslot doesn't support for payments yet."
      )

  defp error_message(_reason), do: nil

  # The start path's catch-all.
  defp connect_error_message(reason) do
    error_message(reason) ||
      dgettext("dashboard_payments", "Could not start Stripe connection. Please try again.")
  end

  # The callback's catch-all, for a failure after Stripe approved (a changeset
  # error, say): the host has not "started" anything, so this says the
  # connection did not complete.
  defp callback_error_message(reason), do: error_message(reason) || error_message(:oauth_failed)
end
