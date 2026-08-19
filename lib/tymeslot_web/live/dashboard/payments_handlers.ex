defmodule TymeslotWeb.Dashboard.PaymentsHandlers do
  @moduledoc """
  Payments-specific `handle_params/3` logic for `DashboardLive`.

  When the host lands on the integrations hub having just returned from the
  Stripe Express onboarding flow (`?return=1`/`?refresh=1`, carried across from
  the legacy `/dashboard/payments` route), this enqueues a one-shot Stripe
  resync so capability flags refresh without waiting on the next
  `account.updated` webhook. It runs on every `:integrations` render,
  regardless of `Tymeslot.Features.meeting_payments_allowed?/1` (the hub's own
  mount-time gate, read as `payments_allowed`): no feature check is needed
  here because the lookup is scoped to the caller's own account and only acts
  when a genuine return marker is present, so a host without payments access
  simply has no connect account to find.
  """

  import Phoenix.LiveView, only: [connected?: 1]

  alias Tymeslot.MeetingPayments

  @doc """
  Enqueues the Stripe capability resync when the host returns from the Express
  onboarding flow (`?return=1`/`?refresh=1`), and returns the socket unchanged.

  Safe to call on every `:integrations` render: the resync only runs on the
  connected socket and only when a return marker is present, so ordinary hub
  visits are a no-op.
  """
  @spec maybe_enqueue_resync(map(), Phoenix.LiveView.Socket.t()) ::
          Phoenix.LiveView.Socket.t()
  def maybe_enqueue_resync(params, socket) do
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
