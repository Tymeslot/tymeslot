defmodule Tymeslot.Auth.SocialAuthenticationTest do
  @moduledoc """
  Tests for SocialAuthentication module.
  """

  use Tymeslot.DataCase, async: true

  alias Plug.Conn
  alias Tymeslot.Auth.SocialAuthentication

  describe "validate_provider_response/1" do
    test "returns :ok for valid Google provider response" do
      params = %{
        "email" => "test@example.com",
        "provider" => "google",
        "verified_email" => true
      }

      assert :ok = SocialAuthentication.validate_provider_response(params)
    end

    test "returns :ok for valid GitHub provider response" do
      params = %{
        "email" => "test@example.com",
        "provider" => "github",
        "verified_email" => true
      }

      assert :ok = SocialAuthentication.validate_provider_response(params)
    end

    test "returns :ok when verified_email is string 'true'" do
      params = %{
        "email" => "test@example.com",
        "provider" => "google",
        "verified_email" => "true"
      }

      assert :ok = SocialAuthentication.validate_provider_response(params)
    end

    test "returns error for missing email" do
      params = %{
        "provider" => "google",
        "verified_email" => true
      }

      assert {:error, :missing_required_fields, missing} =
               SocialAuthentication.validate_provider_response(params)

      assert "email" in missing
    end

    test "returns error for empty email" do
      params = %{
        "email" => "",
        "provider" => "google",
        "verified_email" => true
      }

      assert {:error, :missing_required_fields, _} =
               SocialAuthentication.validate_provider_response(params)
    end

    test "returns error for missing provider" do
      params = %{
        "email" => "test@example.com",
        "verified_email" => true
      }

      assert {:error, :missing_required_fields, missing} =
               SocialAuthentication.validate_provider_response(params)

      assert "provider" in missing
    end

    test "returns error for unverified email" do
      params = %{
        "email" => "test@example.com",
        "provider" => "google",
        "verified_email" => false
      }

      assert {:error, :email_not_verified} =
               SocialAuthentication.validate_provider_response(params)
    end

    test "returns error for nil verified_email" do
      params = %{
        "email" => "test@example.com",
        "provider" => "google",
        "verified_email" => nil
      }

      assert {:error, :email_not_verified} =
               SocialAuthentication.validate_provider_response(params)
    end

    test "returns error for invalid provider" do
      params = %{
        "email" => "test@example.com",
        "provider" => "facebook",
        "verified_email" => true
      }

      assert {:error, :invalid_provider} =
               SocialAuthentication.validate_provider_response(params)
    end
  end

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
      assert {:error, _} = SocialAuthentication.check_email_availability("test@example.com")
    end

    test "returns error for invalid email format (nil)" do
      assert {:error, "Invalid email format"} = SocialAuthentication.check_email_availability(nil)
    end

    test "returns error for invalid email format (number)" do
      assert {:error, "Invalid email format"} = SocialAuthentication.check_email_availability(123)
    end
  end

  describe "convert_to_atom_keys/1" do
    test "converts string keys to existing atom keys" do
      params = %{"full_name" => "Test User", "timezone" => "America/New_York"}

      result = SocialAuthentication.convert_to_atom_keys(params)

      assert result.full_name == "Test User"
      assert result.timezone == "America/New_York"
    end

    test "handles empty map" do
      assert %{} = SocialAuthentication.convert_to_atom_keys(%{})
    end

    test "preserves values" do
      params = %{
        "full_name" => "Test User",
        "bio" => "A short bio",
        "timezone" => "Europe/London"
      }

      result = SocialAuthentication.convert_to_atom_keys(params)

      assert result.full_name == "Test User"
      assert result.bio == "A short bio"
      assert result.timezone == "Europe/London"
    end

    test "raises for non-existing atom keys" do
      params = %{"this_key_does_not_exist_as_atom_xyz123" => "value"}

      assert_raise ArgumentError, fn ->
        SocialAuthentication.convert_to_atom_keys(params)
      end
    end
  end

  describe "finalize_social_login_registration/3 - validation" do
    test "returns error for missing email in auth_params" do
      auth_params = %{
        "provider" => "google",
        "verified_email" => true
      }

      profile_params = %{full_name: "Test User"}

      temp_user = %{
        provider: "google",
        email: nil,
        verified_email: true,
        google_user_id: "123456"
      }

      assert {:error, :missing_required_fields, _} =
               SocialAuthentication.finalize_social_login_registration(
                 auth_params,
                 profile_params,
                 temp_user
               )
    end

    test "returns error for unverified email" do
      auth_params = %{
        "email" => "test@example.com",
        "provider" => "google",
        "verified_email" => false
      }

      profile_params = %{full_name: "Test User"}

      temp_user = %{
        provider: "google",
        email: "test@example.com",
        verified_email: false,
        google_user_id: "123456"
      }

      assert {:error, :email_not_verified} =
               SocialAuthentication.finalize_social_login_registration(
                 auth_params,
                 profile_params,
                 temp_user
               )
    end

    test "returns error for invalid provider" do
      auth_params = %{
        "email" => "test@example.com",
        "provider" => "invalid_provider",
        "verified_email" => true
      }

      profile_params = %{full_name: "Test User"}

      temp_user = %{
        provider: "invalid_provider",
        email: "test@example.com",
        verified_email: true
      }

      assert {:error, :invalid_provider} =
               SocialAuthentication.finalize_social_login_registration(
                 auth_params,
                 profile_params,
                 temp_user
               )
    end
  end

  describe "generate_oauth_state/1" do
    test "generates base64 encoded state" do
      # Create a simple conn for testing
      conn = %Conn{private: %{}}
      conn = Conn.put_private(conn, :plug_session, %{})

      state = SocialAuthentication.generate_oauth_state(conn)

      assert is_binary(state)
      # Base64 URL encoded should be URL safe
      assert String.match?(state, ~r/^[A-Za-z0-9_-]+$/)
      # Should be of reasonable length (32 bytes = 43 base64 chars)
      assert String.length(state) >= 40
    end
  end
end
