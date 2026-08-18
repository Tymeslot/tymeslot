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

    test "normalises case and surrounding whitespace before the lookup" do
      insert(:user, email: "test@example.com")

      # The lookup downcases and trims its input, so a social provider handing
      # back a differently-cased or padded address must still be recognised as
      # taken — otherwise a second account would be created for the same person
      # and the lower(email) unique index would reject it at insert time.
      assert {:error, _msg} = SocialAuthentication.check_email_availability("TEST@Example.com")

      assert {:error, _msg} =
               SocialAuthentication.check_email_availability("  test@example.com  ")
    end

    test "returns error for invalid email format (nil)" do
      assert {:error, "Invalid email format"} = SocialAuthentication.check_email_availability(nil)
    end

    test "returns error for invalid email format (number)" do
      assert {:error, "Invalid email format"} = SocialAuthentication.check_email_availability(123)
    end
  end
end
