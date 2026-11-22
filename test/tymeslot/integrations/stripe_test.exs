defmodule Tymeslot.Integrations.StripeTest do
  # Not async: every test changes the key in app env.
  use ExUnit.Case, async: false

  import Tymeslot.ConfigTestHelpers

  alias Tymeslot.Integrations.Stripe

  @moduletag :payments

  defp set_keys(tymeslot_key, stripity_key) do
    with_config(:tymeslot, :stripe_secret_key, tymeslot_key)
    with_config(:stripity_stripe, :api_key, stripity_key)
  end

  describe "secret_key/0" do
    test "prefers :tymeslot, :stripe_secret_key" do
      set_keys("sk_test_tymeslot", "sk_test_stripity")
      assert Stripe.secret_key() == "sk_test_tymeslot"
    end

    test "falls back to the stripity_stripe key when the first is blank" do
      set_keys("", "sk_test_stripity")
      assert Stripe.secret_key() == "sk_test_stripity"
    end

    test "is nil when neither is set" do
      set_keys(nil, "")
      assert Stripe.secret_key() == nil
    end
  end

  describe "configured?/0" do
    test "is true with a key" do
      set_keys("sk_test_x", nil)
      assert Stripe.configured?()
    end

    test "is false without one" do
      set_keys(nil, nil)
      refute Stripe.configured?()
    end
  end

  describe "live_mode?/0" do
    test "is true for a live key" do
      set_keys("sk_live_x", nil)
      assert Stripe.live_mode?()
    end

    test "is false for a test key" do
      set_keys("sk_test_x", nil)
      refute Stripe.live_mode?()
    end

    test "is false without a key" do
      set_keys(nil, nil)
      refute Stripe.live_mode?()
    end
  end

  test "api_version/0 is the pinned version" do
    assert Stripe.api_version() == "2025-11-17.clover"
  end
end
