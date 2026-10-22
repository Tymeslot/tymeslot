defmodule Tymeslot.Payments.StripeApiTest do
  # async: false: one test swaps the global :stripe_provider setting.
  use ExUnit.Case, async: false

  @moduletag :payments

  import Mox

  alias Tymeslot.Payments
  alias Tymeslot.Payments.StripeMock

  setup :verify_on_exit!

  # {context function, provider callback, args}
  @operations [
    {:create_stripe_customer, :create_customer, [%{email: "a@example.com"}]},
    {:delete_stripe_customer, :delete_customer, ["cus_1"]},
    {:create_stripe_subscription_checkout, :create_checkout_session_for_subscription,
     [%{mode: "subscription"}]},
    {:create_stripe_billing_portal_session, :create_billing_portal_session,
     ["cus_1", "https://example.com/back"]},
    {:get_stripe_subscription, :get_subscription, ["sub_1"]},
    {:list_stripe_subscriptions, :list_subscriptions, [%{customer: "cus_1"}]},
    {:cancel_stripe_subscription, :cancel_subscription, ["sub_1", [at_period_end: false]]},
    {:resume_stripe_subscription, :resume_subscription, ["sub_1"]},
    {:set_stripe_subscription_automatic_tax, :update_subscription_automatic_tax, ["sub_1", true]},
    {:list_stripe_invoices, :list_invoices, [%{customer: "cus_1"}]},
    {:list_stripe_charges, :list_charges, [%{customer: "cus_1", limit: 100}]},
    {:create_stripe_refund, :create_refund, [%{charge: "ch_1"}, [idempotency_key: "k"]]}
  ]

  describe "Stripe API" do
    for {fun, callback, args} <- @operations do
      test "#{fun} hands its arguments to the provider's #{callback} and returns its answer" do
        fun = unquote(fun)
        args = unquote(Macro.escape(args))

        stub_with_echo(unquote(callback), length(args))

        assert apply(Payments, fun, args) == {:ok, %{args: args}}
      end
    end

    test "passes a provider error through unchanged" do
      expect(StripeMock, :get_subscription, fn "sub_1" -> {:error, :rate_limited} end)

      assert Payments.get_stripe_subscription("sub_1") == {:error, :rate_limited}
    end

    test "resolves the provider at call time, so a runtime override takes effect" do
      defmodule OverrideProvider do
        @spec get_subscription(String.t()) :: {:ok, map()}
        def get_subscription(id), do: {:ok, %{id: id, from: :override}}
      end

      previous = Application.get_env(:tymeslot, :stripe_provider)
      Application.put_env(:tymeslot, :stripe_provider, OverrideProvider)
      on_exit(fn -> Application.put_env(:tymeslot, :stripe_provider, previous) end)

      assert Payments.get_stripe_subscription("sub_1") == {:ok, %{id: "sub_1", from: :override}}
    end
  end

  defp stub_with_echo(callback, 1), do: expect(StripeMock, callback, fn a -> echo([a]) end)
  defp stub_with_echo(callback, 2), do: expect(StripeMock, callback, fn a, b -> echo([a, b]) end)

  defp echo(args), do: {:ok, %{args: args}}
end
