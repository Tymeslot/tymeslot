defmodule Tymeslot.Auth.SocialAuthenticationTest do
  @moduledoc """
  Tests for SocialAuthentication module.
  """

  use Tymeslot.DataCase, async: true
  @moduletag :auth

  alias Tymeslot.Auth.SocialAuthentication

  describe "check_email_availability/1" do
    test "returns :ok when email is not registered" do
      assert :ok = SocialAuthentication.check_email_availability("newuser@example.com")
    end

    test "returns error when email is already registered" do
      existing_user = insert(:user, email: "existing@example.com")

      assert {:error, message} =
               SocialAuthentication.check_email_availability(existing_user.email)

      assert message =~ "already registered"
    end

    test "matches email exactly (case-sensitive in query)" do
      insert(:user, email: "test@example.com")

      # Note: email matching depends on database collation/citext usage
      # Test the actual behavior - exact match should return error
      assert {:error, _msg} = SocialAuthentication.check_email_availability("test@example.com")
    end

    test "returns error for invalid email format (nil)" do
      assert {:error, "Invalid email format"} = SocialAuthentication.check_email_availability(nil)
    end

    test "returns error for invalid email format (number)" do
      assert {:error, "Invalid email format"} = SocialAuthentication.check_email_availability(123)
    end
  end
end
