defmodule Tymeslot.Integrations.StripeTest do
  # Not async: every test changes the key in app env.
  use ExUnit.Case, async: false

  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.Integrations.Stripe

  @moduletag :payments

  defp set_key(key), do: with_config(:tymeslot, :stripe_secret_key, key)

  describe "secret_key/0" do
    test "reads :tymeslot, :stripe_secret_key" do
      set_key("sk_test_tymeslot")
      assert Stripe.secret_key() == "sk_test_tymeslot"
    end

    test "is nil when the key is blank" do
      set_key("")
      assert Stripe.secret_key() == nil
    end

    test "is nil when the key is unset" do
      set_key(nil)
      assert Stripe.secret_key() == nil
    end
  end

  describe "configured?/0" do
    test "is true with a key" do
      set_key("sk_test_x")
      assert Stripe.configured?()
    end

    test "is false without one" do
      set_key(nil)
      refute Stripe.configured?()
    end
  end

  describe "live_mode?/0" do
    test "is true for a live key" do
      set_key("sk_live_x")
      assert Stripe.live_mode?()
    end

    test "is false for a test key" do
      set_key("sk_test_x")
      refute Stripe.live_mode?()
    end

    test "is false without a key" do
      set_key(nil)
      refute Stripe.live_mode?()
    end
  end

  test "api_version/0 is the pinned version" do
    assert Stripe.api_version() == "2025-11-17.clover"
  end
end
