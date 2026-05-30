defmodule Tymeslot.MeetingTypes.PrivateLinkTokenTest do
  @moduledoc """
  Tests for private booking link token signing and verification.
  """
  use ExUnit.Case, async: true

  @moduletag :unit
  @moduletag :meeting_types

  alias Phoenix.Token
  alias Tymeslot.MeetingTypes.PrivateLinkToken

  describe "sign/3 and verify/1" do
    test "round-trips a permanent token" do
      assert {:ok, {1, 42}} =
               PrivateLinkToken.verify(PrivateLinkToken.sign(1, 42))
    end

    test "round-trips a time-limited token that has not expired" do
      assert {:ok, {5, 99}} =
               PrivateLinkToken.verify(PrivateLinkToken.sign(5, 99, 30))
    end

    test "returns :expired for a token with valid_days: 0 equivalent (already past)" do
      # Build a token whose expires_at is in the past by using negative seconds offset
      token =
        Token.sign(
          TymeslotWeb.Endpoint,
          "private_booking_link_v1",
          {7, 3, System.os_time(:second) - 1}
        )

      assert {:error, :expired} = PrivateLinkToken.verify(token)
    end

    test "returns :invalid for a tampered token" do
      assert {:error, :invalid} = PrivateLinkToken.verify("not.a.real.token")
    end

    test "returns :invalid for an empty string" do
      assert {:error, :invalid} = PrivateLinkToken.verify("")
    end

    test "returns :invalid when payload has wrong shape" do
      bad_token =
        Token.sign(TymeslotWeb.Endpoint, "private_booking_link_v1", "wrong_shape")

      assert {:error, :invalid} = PrivateLinkToken.verify(bad_token)
    end

    test "returns :invalid when signed with a different salt" do
      bad_token =
        Token.sign(TymeslotWeb.Endpoint, "wrong_salt", {1, 2, nil})

      assert {:error, :invalid} = PrivateLinkToken.verify(bad_token)
    end

    test "permanent token contains only user_id and meeting_type_id in result" do
      token = PrivateLinkToken.sign(10, 20)
      assert {:ok, {10, 20}} = PrivateLinkToken.verify(token)
    end

    test "tokens for different meeting types are distinct" do
      t1 = PrivateLinkToken.sign(1, 1)
      t2 = PrivateLinkToken.sign(1, 2)

      assert t1 != t2

      assert {:ok, {1, 1}} = PrivateLinkToken.verify(t1)
      assert {:ok, {1, 2}} = PrivateLinkToken.verify(t2)
    end

    test "tokens for different users are distinct" do
      t1 = PrivateLinkToken.sign(1, 42)
      t2 = PrivateLinkToken.sign(2, 42)

      assert t1 != t2
    end

    test "time-limited token still valid one second before expiry" do
      # expires in 1 day — definitely not expired
      token = PrivateLinkToken.sign(1, 1, 1)
      assert {:ok, {1, 1}} = PrivateLinkToken.verify(token)
    end
  end

  describe "generate_private_link_token/2 (public MeetingTypes API)" do
    test "delegates to PrivateLinkToken.sign with user_id and id from struct" do
      mt = %{id: 7, user_id: 3}
      token = Tymeslot.MeetingTypes.generate_private_link_token(mt)
      assert {:ok, {3, 7}} = PrivateLinkToken.verify(token)
    end

    test "passes valid_days through" do
      mt = %{id: 7, user_id: 3}
      token = Tymeslot.MeetingTypes.generate_private_link_token(mt, 14)
      assert {:ok, {3, 7}} = PrivateLinkToken.verify(token)
    end
  end
end
