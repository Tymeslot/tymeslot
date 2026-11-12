defmodule Tymeslot.StripeConnectTestHelpers do
  @moduledoc """
  Shared steps for tests that connect a host's Stripe account through OAuth,
  with the Stripe adapter mocked. Import it in a test module that uses
  `Mox`.
  """

  import ExUnit.Assertions, only: [assert: 1]
  import Mox, only: [expect: 4]
  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.MeetingPayments.ConnectAccounts
  alias Tymeslot.MeetingPayments.StripeAdapterMock

  @doc "Setup callback turning meeting payments on."
  @spec enable_meeting_payments(map()) :: :ok
  def enable_meeting_payments(_context) do
    with_config(:tymeslot,
      meeting_payments_enabled: true,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker
    )

    :ok
  end

  @doc "Starts onboarding for the user and returns the OAuth `state` value."
  @spec started_state(map()) :: String.t()
  def started_state(user) do
    {:ok, %{url: url}} = ConnectAccounts.start_onboarding(user)
    url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")
  end

  @doc "Runs the whole OAuth callback for `stripe_account_id`, a French EUR account."
  @spec connect_account(map(), String.t()) :: :ok
  def connect_account(user, stripe_account_id) do
    state = started_state(user)
    code = "code_" <> stripe_account_id
    expect_exchange(code, stripe_account_id)
    expect_retrieve(stripe_account_id, %{"country" => "FR", "default_currency" => "eur"})

    assert {:ok, _account} = ConnectAccounts.complete_oauth_callback(user, code, state)
    :ok
  end

  @doc "Expects one OAuth code exchange for `code`, yielding `stripe_account_id`."
  @spec expect_exchange(String.t(), String.t()) :: Mox.t()
  def expect_exchange(code, stripe_account_id) do
    expect(StripeAdapterMock, :exchange_oauth_code, 1, fn ^code ->
      {:ok, %{stripe_user_id: stripe_account_id}}
    end)
  end

  @doc "Expects one account read for `stripe_account_id`, merging `attrs` into a bare snapshot."
  @spec expect_retrieve(String.t(), map()) :: Mox.t()
  def expect_retrieve(stripe_account_id, attrs) do
    expect(StripeAdapterMock, :retrieve_account, 1, fn ^stripe_account_id ->
      {:ok, snapshot(stripe_account_id, attrs)}
    end)
  end

  @doc "A Stripe account snapshot with every capability off, overridden by `attrs`."
  @spec snapshot(String.t(), map()) :: map()
  def snapshot(stripe_account_id, attrs) do
    Map.merge(
      %{
        "id" => stripe_account_id,
        "charges_enabled" => false,
        "payouts_enabled" => false,
        "details_submitted" => false,
        "requirements" => %{"disabled_reason" => nil}
      },
      attrs
    )
  end
end
