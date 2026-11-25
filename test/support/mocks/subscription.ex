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

    # No subscription is recorded unless a test says otherwise, as for Core
    # standalone.
    stub(Tymeslot.Payments.SubscriptionManagerMock, :get_subscription_by_customer_id, fn _id ->
      nil
    end)

    stub(
      Tymeslot.Payments.SubscriptionManagerMock,
      :get_subscription_by_subscription_id,
      fn _id ->
        nil
      end
    )

    run_extra_stubs(opts)
  end

  # A deployment layered on Core can add LiveView hooks that consult mocks of
  # its own on every mount. It lists `{module, function}` pairs under
  # `:test_subscription_mock_hooks`, each called with this function's opts, so
  # its stubs are in place at the same point in every case template's setup
  # (after `Mox.set_mox_from_context/1`, so shared mode sees them). Core lists
  # none.
  defp run_extra_stubs(opts) do
    :tymeslot
    |> Application.get_env(:test_subscription_mock_hooks, [])
    |> Enum.each(fn {module, function} -> apply(module, function, [opts]) end)
  end
end
