defmodule Tymeslot.Auth.OAuth.UserProcessorTest do
  @moduledoc """
  How a provider's userinfo becomes a sign-in identity: which ID is used and
  which emails are trusted. Only the provider's HTTP endpoints are stubbed.
  """

  use ExUnit.Case, async: false

  @moduletag :auth

  import Tymeslot.Test.OAuthProviderStub

  alias Plug.Conn
  alias Tymeslot.Auth.OAuth.UserProcessor

  setup :setup_providers

  describe "SSO" do
    test "uses the sub claim and trusts an email with email_verified true" do
      stub_sso(%{
        "sub" => "user-123",
        "email" => "sso@example.com",
        "name" => "SSO User",
        "email_verified" => true
      })

      assert {:ok, identity} = UserProcessor.fetch_identity(:oauth, "token")

      assert identity == %{
               provider_uid: "user-123",
               email: "sso@example.com",
               email_from_provider: true,
               name: "SSO User"
             }
    end

    test "sends the token as a Bearer credential" do
      stub_sso(%{"sub" => "user-1"})

      UserProcessor.fetch_identity(:oauth, "the-token")

      assert_received {:provider_request, "GET", "/userinfo", _params, "Bearer the-token"}
    end

    test "accepts the string \"true\" for email_verified" do
      stub_sso(%{"sub" => "4", "email" => "a@b.com", "email_verified" => "true"})

      assert {:ok, %{email: "a@b.com", email_from_provider: true}} =
               UserProcessor.fetch_identity(:oauth, "token")
    end

    for claim <- [false, "false", nil] do
      test "drops an email whose email_verified is #{inspect(claim)}" do
        stub_sso(%{"sub" => "2", "email" => "a@b.com", "email_verified" => unquote(claim)})

        assert {:ok, %{email: nil, email_from_provider: false}} =
                 UserProcessor.fetch_identity(:oauth, "token")
      end
    end

    for email <- [nil, "", 12_345] do
      test "treats #{inspect(email)} as no email" do
        stub_sso(%{"sub" => "1", "email" => unquote(email), "email_verified" => true})

        assert {:ok, %{email: nil, email_from_provider: false}} =
                 UserProcessor.fetch_identity(:oauth, "token")
      end
    end

    test "coerces an integer sub to a string" do
      stub_sso(%{"sub" => 12_345})

      assert {:ok, %{provider_uid: "12345"}} = UserProcessor.fetch_identity(:oauth, "token")
    end

    for sub <- ["", false] do
      test "rejects the sub #{inspect(sub)}" do
        stub_sso(%{"sub" => unquote(sub)})

        assert {:error, :invalid_user_info} = UserProcessor.fetch_identity(:oauth, "token")
      end
    end

    test "ignores id and user_id unless the fallback is enabled" do
      stub_sso(%{"id" => "alt-456", "user_id" => "uid-789"})

      assert {:error, :invalid_user_info} = UserProcessor.fetch_identity(:oauth, "token")
    end

    test "falls back to id, then user_id, when enabled" do
      config = Application.get_env(:tymeslot, :oauth_provider)

      Application.put_env(
        :tymeslot,
        :oauth_provider,
        Keyword.put(config, :allow_id_fallback, true)
      )

      stub_sso(%{"id" => "alt-456"})
      assert {:ok, %{provider_uid: "alt-456"}} = UserProcessor.fetch_identity(:oauth, "token")

      stub_sso(%{"user_id" => "uid-789"})
      assert {:ok, %{provider_uid: "uid-789"}} = UserProcessor.fetch_identity(:oauth, "token")
    end
  end

  describe "Google" do
    test "trusts the email only when verified_email is true" do
      stub_google(%{"id" => "g-123", "email" => "g@example.com", "verified_email" => true})

      assert {:ok, %{provider_uid: "g-123", email: "g@example.com", email_from_provider: true}} =
               UserProcessor.fetch_identity(:google, "token")

      stub_google(%{"id" => "g-123", "email" => "g@example.com", "verified_email" => false})

      assert {:ok, %{email: nil, email_from_provider: false}} =
               UserProcessor.fetch_identity(:google, "token")
    end
  end

  describe "GitHub" do
    test "sends the token with GitHub's token scheme" do
      stub_github(%{"id" => 1}, [])

      UserProcessor.fetch_identity(:github, "the-token")

      assert_received {:provider_request, "GET", "/user", _params, "token the-token"}
      assert_received {:provider_request, "GET", "/user/emails", _params, "token the-token"}
    end

    test "stringifies the numeric ID and takes the primary verified address" do
      stub_github(%{"id" => 123, "email" => "public@example.com"}, [
        %{"email" => "other@example.com", "primary" => false, "verified" => true},
        %{"email" => "primary@example.com", "primary" => true, "verified" => true}
      ])

      assert {:ok,
              %{provider_uid: "123", email: "primary@example.com", email_from_provider: true}} =
               UserProcessor.fetch_identity(:github, "token")
    end

    test "falls back to any verified address when the primary is unverified" do
      stub_github(%{"id" => 1}, [
        %{"email" => "primary@example.com", "primary" => true, "verified" => false},
        %{"email" => "backup@example.com", "primary" => false, "verified" => true}
      ])

      assert {:ok, %{email: "backup@example.com"}} =
               UserProcessor.fetch_identity(:github, "token")
    end

    test "ignores the public profile email, which carries no verification status" do
      stub_github(%{"id" => 1, "email" => "public@example.com"}, [])

      assert {:ok, %{email: nil, email_from_provider: false}} =
               UserProcessor.fetch_identity(:github, "token")
    end

    test "leaves the email to the user when the address list cannot be read" do
      stub_provider(%{
        "/user" => %{"id" => 1},
        "/user/emails" => &Conn.send_resp(&1, 403, "{}")
      })

      assert {:ok, %{provider_uid: "1", email: nil}} =
               UserProcessor.fetch_identity(:github, "token")
    end
  end
end
