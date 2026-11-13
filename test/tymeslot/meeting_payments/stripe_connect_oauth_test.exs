defmodule Tymeslot.MeetingPayments.StripeConnectOAuthTest do
  use Tymeslot.DataCase, async: false

  @moduletag :payments

  import Tymeslot.ConfigTestHelpers

  alias Phoenix.Token
  alias Tymeslot.MeetingPayments.StripeConnectOAuth
  alias Tymeslot.SignedToken
  alias TymeslotWeb.Endpoint

  describe "authorize_url/2" do
    test "the authorise URL carries the registered redirect and a verifiable state" do
      url = StripeConnectOAuth.authorize_url(42, "nonce-1")
      uri = URI.parse(url)
      params = URI.decode_query(uri.query)

      assert "#{uri.scheme}://#{uri.host}#{uri.path}" ==
               "https://connect.stripe.com/oauth/authorize"

      assert params["client_id"] == "ca_test"
      assert params["scope"] == "read_write"
      assert params["response_type"] == "code"
      assert params["redirect_uri"] == StripeConnectOAuth.redirect_uri()
      assert String.ends_with?(params["redirect_uri"], "/dashboard/payments/connect/callback")

      assert StripeConnectOAuth.verify_state(params["state"]) ==
               {:ok, %{user_id: 42, nonce: "nonce-1"}}
    end
  end

  describe "verify_state/1" do
    test "a tampered state is invalid" do
      state =
        StripeConnectOAuth.authorize_url(1, "n")
        |> URI.parse()
        |> Map.fetch!(:query)
        |> URI.decode_query()
        |> Map.fetch!("state")

      assert StripeConnectOAuth.verify_state(state <> "x") == {:error, :invalid_state}
    end

    test "a correctly signed state with the wrong payload is invalid" do
      state = SignedToken.sign(:stripe_connect_state, %{unrelated: true})

      assert StripeConnectOAuth.verify_state(state) == {:error, :invalid_state}
    end

    test "a state a little under 24 hours old is still accepted" do
      aged =
        Token.sign(Endpoint, "stripe_connect_state", %{user_id: 1, nonce: "n"},
          signed_at: System.system_time(:second) - 23 * 3600
        )

      assert StripeConnectOAuth.verify_state(aged) == {:ok, %{user_id: 1, nonce: "n"}}
    end

    test "an expired state is reported as expired" do
      aged =
        Token.sign(Endpoint, "stripe_connect_state", %{user_id: 1, nonce: "n"},
          signed_at: System.system_time(:second) - 25 * 3600
        )

      assert StripeConnectOAuth.verify_state(aged) == {:error, :expired_state}
    end
  end

  describe "configured?/0" do
    test "is false without a client ID" do
      with_config(:tymeslot, :stripe_connect_client_id, nil)
      refute StripeConnectOAuth.configured?()
    end

    test "is false for an empty client ID" do
      with_config(:tymeslot, :stripe_connect_client_id, "")
      refute StripeConnectOAuth.configured?()
    end

    test "is false for a whitespace-only client ID" do
      with_config(:tymeslot, :stripe_connect_client_id, "  ")
      refute StripeConnectOAuth.configured?()
    end

    test "is true with a client ID" do
      with_config(:tymeslot, :stripe_connect_client_id, "ca_real")
      assert StripeConnectOAuth.configured?()
    end
  end
end
