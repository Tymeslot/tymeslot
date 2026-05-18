defmodule Tymeslot.Mocks.Subscription do
  @moduledoc """
  SaaS subscription manager mocks.

  See `Tymeslot.TestMocks` for the public API (`setup_subscription_mocks/1`).
  """

  import Mox

  @spec setup(keyword()) :: term()
  def setup(opts \\ []) do
    show_branding = Keyword.get(opts, :show_branding, true)

    stub(Tymeslot.Payments.SubscriptionManagerMock, :should_show_branding?, fn _user_id ->
      show_branding
    end)
  end
end
