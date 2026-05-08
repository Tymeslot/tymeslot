defmodule Tymeslot.MeetingPayments.ConnectAccounts do
  @moduledoc """
  Stripe Connect lifecycle for hosts.

  Owns the placeholder-first onboarding flow: a row is persisted before
  Stripe is ever called so that a crash mid-flight cannot orphan a real
  Stripe account. The Stripe API call itself is idempotency-keyed by the
  user id, which makes a retry after a crash safe.
  """

  alias Tymeslot.MeetingPayments.ConnectAccountQueries
  alias Tymeslot.MeetingPayments.ConnectAccountSchema
  alias Tymeslot.MeetingPayments.StripeAdapter
  alias TymeslotWeb.Endpoint

  @type account :: ConnectAccountSchema.t()

  @spec start_onboarding(user :: %{id: integer()}, opts :: keyword()) ::
          {:ok, %{url: String.t(), account: account()}} | {:error, term()}
  def start_onboarding(user, opts) do
    country = Keyword.fetch!(opts, :country)

    with {:ok, account} <- ensure_placeholder(user.id, country),
         {:ok, stripe_account} <- create_stripe_account(user.id, country),
         {:ok, account} <-
           ConnectAccountQueries.update(account, %{
             stripe_account_id: stripe_account.id,
             default_currency: stripe_account.default_currency,
             status: "active"
           }),
         {:ok, link} <- create_account_link(stripe_account.id) do
      {:ok, %{url: link.url, account: account}}
    end
  end

  @spec disconnect(user :: %{id: integer()}) :: :ok
  def disconnect(user) do
    now = DateTime.utc_now(:second)
    ConnectAccountQueries.soft_delete_for_user(user.id, now)
    :ok
  end

  @spec apply_account_event(map()) :: :ok
  def apply_account_event(%{"id" => stripe_account_id, "created" => stripe_created} = event) do
    case ConnectAccountQueries.by_stripe_account_id(stripe_account_id) do
      nil ->
        :ok

      %ConnectAccountSchema{} = local ->
        event_dt = DateTime.from_unix!(stripe_created)

        if older?(event_dt, local.last_account_event_at) do
          :ok
        else
          now = DateTime.utc_now(:second)

          {:ok, _updated} =
            ConnectAccountQueries.update(local, %{
              charges_enabled: event["charges_enabled"],
              payouts_enabled: event["payouts_enabled"],
              details_submitted: event["details_submitted"],
              disabled_reason: get_in(event, ["requirements", "disabled_reason"]),
              last_synced_at: now,
              last_account_event_at: event_dt
            })

          :ok
        end
    end
  end

  @spec ensure_placeholder(integer(), String.t()) ::
          {:ok, account()} | {:error, Ecto.Changeset.t()}
  defp ensure_placeholder(user_id, country) do
    case ConnectAccountQueries.live_for_user(user_id) do
      nil -> ConnectAccountQueries.insert_placeholder(user_id, country)
      %ConnectAccountSchema{} = account -> {:ok, account}
    end
  end

  defp create_stripe_account(user_id, country) do
    StripeAdapter.create_account(
      %{
        type: "standard",
        country: country,
        capabilities: %{
          card_payments: %{requested: true},
          transfers: %{requested: true}
        }
      },
      idempotency_key: "account:#{user_id}"
    )
  end

  defp create_account_link(stripe_account_id) do
    StripeAdapter.create_account_link(%{
      account: stripe_account_id,
      type: "account_onboarding",
      refresh_url: dashboard_url("/dashboard/payments?refresh=1"),
      return_url: dashboard_url("/dashboard/payments?return=1")
    })
  end

  defp dashboard_url(path), do: Endpoint.url() <> path

  defp older?(_event_dt, nil), do: false
  defp older?(event_dt, last), do: DateTime.compare(event_dt, last) == :lt
end
