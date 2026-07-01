defmodule TymeslotWeb.Live.Scheduling.PreviewTokenTest do
  use ExUnit.Case, async: true

  @moduletag :scheduling
  @moduletag :unit

  alias Phoenix.Token
  alias TymeslotWeb.Endpoint
  alias TymeslotWeb.Live.Scheduling.PreviewToken

  @salt "booking owner preview"

  describe "owner?/2" do
    test "returns true for a valid token bound to the matching user id" do
      user_id = 42
      token = PreviewToken.sign(user_id)
      assert PreviewToken.owner?(token, user_id)
    end

    test "returns false when the token is valid but bound to a different user id" do
      token = PreviewToken.sign(100)
      refute PreviewToken.owner?(token, 999)
    end

    test "returns false for a forged / tampered token string" do
      refute PreviewToken.owner?("not.a.real.token", 1)
      refute PreviewToken.owner?("SFMyNTY.TAMPERED.SIGNATURE", 1)
    end

    test "returns false when token is nil" do
      refute PreviewToken.owner?(nil, 1)
    end

    test "returns false when token is a non-binary term" do
      refute PreviewToken.owner?(123, 1)
      refute PreviewToken.owner?(:atom, 1)
    end

    test "returns false when owner_user_id is nil" do
      token = PreviewToken.sign(1)
      refute PreviewToken.owner?(token, nil)
    end

    test "returns false for an expired token" do
      user_id = 7
      # Sign as if the token was issued more than 1 hour ago — the module's
      # max_age is 3600 s. `Phoenix.Token.sign/4` accepts a `:signed_at`
      # timestamp (seconds since epoch) so we can back-date without sleeping.
      expired_token =
        Token.sign(
          Endpoint,
          @salt,
          user_id,
          signed_at: System.system_time(:second) - 3601
        )

      refute PreviewToken.owner?(expired_token, user_id)
    end
  end
end
