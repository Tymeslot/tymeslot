defmodule TymeslotWeb.Dashboard.PaymentsController do
  @moduledoc """
  Controller for payments-dashboard side effects that need a full
  redirect (rather than a LiveView push_navigate) — currently the
  Stripe Connect onboarding kick-off.
  """

  use TymeslotWeb, :controller

  alias Tymeslot.MeetingPayments

  @spec connect(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def connect(conn, _params) do
    user = conn.assigns.current_user

    case MeetingPayments.start_onboarding(user, country: country_for_user(user)) do
      {:ok, %{url: url}} ->
        redirect(conn, external: url)

      {:error, _reason} ->
        conn
        |> put_flash(:error, "Could not start Stripe connection. Please try again.")
        |> redirect(to: ~p"/dashboard/payments")
    end
  end

  # The user's profile currently carries no country field. Fall back to the
  # operator-configured default (MEETING_PAYMENTS_DEFAULT_COUNTRY env var,
  # defaulting to "ch" when unset).
  defp country_for_user(_user) do
    Application.get_env(:tymeslot, :meeting_payments_default_country, "ch")
  end
end
