defmodule TymeslotWeb.Dashboard.PaymentsController do
  @moduledoc """
  Controller for payments-dashboard side effects that need a full
  redirect (rather than a LiveView push_navigate) — currently the
  Stripe Connect onboarding kick-off.
  """

  use TymeslotWeb, :controller
  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Tymeslot.MeetingPayments

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
          reason: inspect(reason)
        )

        conn
        |> put_flash(:error, connect_error_message(reason))
        |> redirect(to: ~p"/dashboard/payments")
    end
  end

  defp connect_error_message(:feature_disabled),
    do: dgettext("dashboard_payments", "Meeting payments are not enabled for this account.")

  defp connect_error_message(plan_error) when plan_error in [:pro_required, :insufficient_plan],
    do: dgettext("dashboard_payments", "Meeting payments require an upgraded plan.")

  defp connect_error_message(:account_creation_restricted),
    do:
      dgettext(
        "dashboard_payments",
        "Payment setup is temporarily unavailable. Please try again later."
      )

  defp connect_error_message(_reason),
    do: dgettext("dashboard_payments", "Could not start Stripe connection. Please try again.")
end
