defmodule TymeslotWeb.Dashboard.PaymentsController do
  @moduledoc """
  Controller for payments-dashboard side effects that need a full
  redirect (rather than a LiveView push_navigate) — currently the
  Stripe Connect onboarding kick-off.
  """

  use TymeslotWeb, :controller

  require Logger

  alias Tymeslot.Features
  alias Tymeslot.MeetingPayments

  @spec connect(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def connect(conn, _params) do
    user = conn.assigns.current_user

    # Server-side enforcement: the UI hides the Connect button when the user
    # lacks access, but a forged POST must not be able to start onboarding or
    # bypass the operator's "meeting payments" toggle. Core's default checker
    # gates on the runtime flag; SaaS overrides it to require a Pro plan.
    #
    # `:stripe_required` is treated as "allowed" — that error means the user has
    # the plan but no charges-enabled Connect account yet, which is precisely
    # what this onboarding flow exists to establish. Mirrors the dashboard gate
    # in `PaymentsHandlers.handle/2`.
    with :ok <- check_connect_access(user.id),
         {:ok, %{url: url}} <-
           MeetingPayments.start_onboarding(user, country: country_for_user(user)) do
      redirect(conn, external: url)
    else
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

  defp check_connect_access(user_id) do
    case Features.check_access(user_id, :meeting_payments) do
      :ok -> :ok
      {:error, :stripe_required} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp connect_error_message(:feature_disabled),
    do: "Meeting payments are not enabled for this account."

  defp connect_error_message(plan_error) when plan_error in [:pro_required, :insufficient_plan],
    do: "Meeting payments require an upgraded plan."

  defp connect_error_message(_reason),
    do: "Could not start Stripe connection. Please try again."

  # The user's profile currently carries no country field. Fall back to the
  # operator-configured default (MEETING_PAYMENTS_DEFAULT_COUNTRY env var,
  # defaulting to "ch" when unset).
  defp country_for_user(_user) do
    Application.get_env(:tymeslot, :meeting_payments_default_country, "ch")
  end
end
