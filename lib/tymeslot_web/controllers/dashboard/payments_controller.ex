defmodule TymeslotWeb.Dashboard.PaymentsController do
  @moduledoc """
  Controller for payments-dashboard side effects that need a full
  redirect (rather than a LiveView push_navigate) — currently the
  Stripe Connect onboarding kick-off.
  """

  use TymeslotWeb, :controller
  use Gettext, backend: TymeslotWeb.Gettext

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
    # what this onboarding flow exists to establish. Mirrors the payments-tab
    # gate in the integrations hub (`payments_allowed`).
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

  # Uses the shared boolean predicate for the yes/no decision, and only falls
  # back to the raw `check_access/2` reason when denied, since the caller
  # renders that reason into a specific flash message.
  defp check_connect_access(user_id) do
    if Features.meeting_payments_allowed?(user_id) do
      :ok
    else
      Features.check_access(user_id, :meeting_payments)
    end
  end

  defp connect_error_message(:feature_disabled),
    do: dgettext("dashboard_payments", "Meeting payments are not enabled for this account.")

  defp connect_error_message(plan_error) when plan_error in [:pro_required, :insufficient_plan],
    do: dgettext("dashboard_payments", "Meeting payments require an upgraded plan.")

  defp connect_error_message(%Stripe.Error{} = error) do
    if account_creation_restricted?(error) do
      dgettext(
        "dashboard_payments",
        "Payment setup is temporarily unavailable. Please try again later."
      )
    else
      dgettext("dashboard_payments", "Could not start Stripe connection. Please try again.")
    end
  end

  defp connect_error_message(_reason),
    do: dgettext("dashboard_payments", "Could not start Stripe connection. Please try again.")

  # Stripe's risk system can place a temporary hold on the platform account's
  # ability to create new connected accounts ("…temporarily restricted your
  # ability to create this type of connected account…"). This is an
  # operator-side hold, lifted only from the Stripe Dashboard — an immediate
  # client retry cannot succeed, so we surface "try again later" rather than
  # the generic "try again". The message text is the only signal Stripe gives
  # to distinguish this from other invalid_request errors.
  defp account_creation_restricted?(%Stripe.Error{
         code: :invalid_request_error,
         message: message
       })
       when is_binary(message),
       do: String.contains?(message, "temporarily restricted")

  defp account_creation_restricted?(_error), do: false

  # The user's profile currently carries no country field. Fall back to the
  # operator-configured default (MEETING_PAYMENTS_DEFAULT_COUNTRY env var,
  # defaulting to "ch" when unset).
  defp country_for_user(_user) do
    Application.get_env(:tymeslot, :meeting_payments_default_country, "ch")
  end
end
