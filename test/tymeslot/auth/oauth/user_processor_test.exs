defmodule Tymeslot.Auth.OAuth.UserProcessorTest do
  use ExUnit.Case, async: true
  @moduletag :auth

  alias Tymeslot.Auth.OAuth.UserProcessor

  describe "process_user/2" do
    test ":oauth with sub claim" do
      user_info = %{
        "sub" => "user-123",
        "email" => "sso@example.com",
        "name" => "SSO User",
        "email_verified" => true
      }

      assert {:ok, user} = UserProcessor.process_user(:oauth, user_info)

      assert user.provider_uid == "user-123"
      assert user.email == "sso@example.com"
      assert user.name == "SSO User"
      assert user.is_verified == true
      assert user.email_from_provider == true
    end

    test ":oauth falls back to id when sub is missing" do
      user_info = %{
        "id" => "alt-456",
        "email" => "alt@example.com",
        "name" => "Alt User"
      }

      assert {:ok, user} = UserProcessor.process_user(:oauth, user_info)

      assert user.provider_uid == "alt-456"
      assert user.email == "alt@example.com"
    end

    test ":oauth falls back to user_id when sub and id are missing" do
      user_info = %{
        "user_id" => "uid-789",
        "email" => "uid@example.com"
      }

      assert {:ok, user} = UserProcessor.process_user(:oauth, user_info)

      assert user.provider_uid == "uid-789"
    end

    test ":oauth returns error when no identifier is available" do
      user_info = %{"email" => "no-id@example.com"}

      assert {:error, :invalid_user_info} = UserProcessor.process_user(:oauth, user_info)
    end

    test ":oauth respects email_verified claim" do
      assert {:ok, verified} =
               UserProcessor.process_user(:oauth, %{
                 "sub" => "1",
                 "email" => "a@b.com",
                 "email_verified" => true
               })

      assert verified.is_verified == true

      assert {:ok, unverified} =
               UserProcessor.process_user(:oauth, %{
                 "sub" => "2",
                 "email" => "a@b.com",
                 "email_verified" => false
               })

      assert unverified.is_verified == false

      assert {:ok, missing} =
               UserProcessor.process_user(:oauth, %{"sub" => "3", "email" => "a@b.com"})

      assert missing.is_verified == false
    end

    test ":github with valid user info" do
      user_info = %{"id" => 123, "email" => "gh@example.com", "name" => "GH User"}

      assert {:ok, user} = UserProcessor.process_user(:github, user_info)

      assert user.github_user_id == 123
      assert user.email == "gh@example.com"
      assert user.is_verified == true
    end

    test ":google with valid user info" do
      user_info = %{"id" => "g-123", "email" => "g@example.com", "name" => "G User"}

      assert {:ok, user} = UserProcessor.process_user(:google, user_info)

      assert user.google_user_id == "g-123"
      assert user.email == "g@example.com"
    end

    test "unknown provider returns error" do
      assert {:error, :invalid_user_info} = UserProcessor.process_user(:unknown, %{})
    end
  end

  describe "extract_email edge cases" do
    test "nil email in user_info" do
      assert {:ok, user} =
               UserProcessor.process_user(:oauth, %{"sub" => "1", "email" => nil})

      assert user.email == nil
      assert user.email_from_provider == false
    end

    test "empty string email" do
      assert {:ok, user} =
               UserProcessor.process_user(:oauth, %{"sub" => "1", "email" => ""})

      assert user.email == nil
    end

    test "non-string email value" do
      assert {:ok, user} =
               UserProcessor.process_user(:oauth, %{"sub" => "1", "email" => 12345})

      assert user.email == nil
    end
  end
end
