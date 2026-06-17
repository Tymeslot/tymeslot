defmodule TymeslotWeb.Dashboard.PaymentsHandlers do
  @moduledoc """
  Payments-specific `handle_params/3` logic for `DashboardLive`.

  The `:payments` action is gated behind the `:meeting_payments` feature: when
  the host cannot access it, this module redirects to the dashboard root with a
  feature-appropriate flash. When access is granted and the host has just
  returned from the Stripe Express onboarding flow (`?return=1`/`?refresh=1`),
  it enqueues a one-shot Stripe resync so capability flags refresh without
  waiting on the next `account.updated` webhook.
  """

  use TymeslotWeb, :verified_routes

  import Phoenix.LiveView, only: [connected?: 1, put_flash: 3, push_navigate: 2]

  alias Tymeslot.Features
  alias Tymeslot.MeetingPayments

  @doc """
  Gates the `:payments` action and, when access is granted, performs the
  Stripe-return resync.

  Returns the socket — possibly with a queued `push_navigate` redirect when the
  feature is not accessible. Safe to call on the static (disconnected) render:
  the gate runs unconditionally so the redirect happens immediately, while the
  resync only runs on the connected socket.
  """
  @spec handle(map(), Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def handle(params, socket) do
    user = socket.assigns.current_user

    case Features.check_access(user.id, :meeting_payments) do
      access when access == :ok or access == {:error, :stripe_required} ->
        maybe_enqueue_resync(params, socket)

      {:error, plan_error} when plan_error in [:insufficient_plan, :pro_required] ->
        socket
        |> put_flash(:error, "Meeting payments require an upgraded plan.")
        |> push_navigate(to: ~p"/dashboard")

      {:error, _reason} ->
        socket
        |> put_flash(:error, "Meeting payments are not available on this instance.")
        |> push_navigate(to: ~p"/dashboard")
    end
  end

  # Enqueue a Stripe resync when the host returns from the Express onboarding
  # flow. Worker uniqueness keeps repeated returns within a short window from
  # piling up duplicate jobs.
  defp maybe_enqueue_resync(params, socket) do
    returning? = Map.has_key?(params, "return") or Map.has_key?(params, "refresh")

    if connected?(socket) and returning? do
      case MeetingPayments.get_connect_account_for_user(socket.assigns.current_user.id) do
        %{stripe_account_id: stripe_account_id} when is_binary(stripe_account_id) ->
          MeetingPayments.enqueue_resync_for_account(stripe_account_id)

        _missing ->
          :noop
      end
    end

    socket
  end
end
