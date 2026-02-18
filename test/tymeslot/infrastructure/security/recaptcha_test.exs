defmodule Tymeslot.Infrastructure.Security.RecaptchaTest do
  use Tymeslot.DataCase, async: false

  @moduletag :infrastructure

  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Infrastructure.Security.Recaptcha
  import Mox

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup do
    old_client = Application.get_env(:tymeslot, :http_client_module)
    Application.put_env(:tymeslot, :http_client_module, HTTPClientMock)

    # Save original secret key to restore it later
    original_secret = System.get_env("RECAPTCHA_SECRET_KEY")
    System.put_env("RECAPTCHA_SECRET_KEY", "test_secret")

    on_exit(fn ->
      if old_client do
        Application.put_env(:tymeslot, :http_client_module, old_client)
      else
        Application.delete_env(:tymeslot, :http_client_module)
      end

      if original_secret do
        System.put_env("RECAPTCHA_SECRET_KEY", original_secret)
      else
        System.delete_env("RECAPTCHA_SECRET_KEY")
      end
    end)

    :ok
  end

  describe "verify/2" do
    test "returns :ok with score when Google returns success" do
      token = "valid_token"

      response_body =
        Jason.encode!(%{
          "success" => true,
          "score" => 0.9,
          "action" => "login",
          "hostname" => "localhost"
        })

      expect(HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: response_body}}
      end)

      assert {:ok, %{score: 0.9, action: "login", hostname: "localhost"}} =
               Recaptcha.verify(token)
    end

    test "returns :error when score is below minimum" do
      token = "low_score_token"

      response_body =
        Jason.encode!(%{
          "success" => true,
          "score" => 0.1,
          "action" => "login",
          "hostname" => "localhost"
        })

      expect(HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: response_body}}
      end)

      assert {:error, :recaptcha_score_too_low} = Recaptcha.verify(token, min_score: 0.5)
    end

    test "returns :error when action mismatches" do
      token = "token"

      response_body =
        Jason.encode!(%{
          "success" => true,
          "score" => 0.9,
          "action" => "wrong_action"
        })

      expect(HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: response_body}}
      end)

      assert {:error, :recaptcha_action_mismatch} =
               Recaptcha.verify(token, expected_action: "login")
    end

    test "returns :error when hostname mismatches" do
      token = "token"

      response_body =
        Jason.encode!(%{
          "success" => true,
          "score" => 0.9,
          "hostname" => "wrong.com"
        })

      expect(HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: response_body}}
      end)

      assert {:error, :recaptcha_hostname_mismatch} =
               Recaptcha.verify(token, expected_hostnames: ["correct.com"])
    end

    test "returns :error when token is too large" do
      large_token = String.duplicate("a", 5001)
      assert {:error, :invalid_token} = Recaptcha.verify(large_token)
    end

    test "returns :error when token is empty or nil" do
      assert {:error, :invalid_token} = Recaptcha.verify("")
      assert {:error, :invalid_token} = Recaptcha.verify(nil)
    end

    test "returns :error when secret key is missing" do
      System.delete_env("RECAPTCHA_SECRET_KEY")
      assert {:error, :recaptcha_configuration_error} = Recaptcha.verify("token")
    end

    test "handles Google API returning success: false" do
      token = "invalid_token"

      response_body =
        Jason.encode!(%{
          "success" => false,
          "error-codes" => ["invalid-input-response"]
        })

      expect(HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: response_body}}
      end)

      assert {:error, :recaptcha_verification_failed} = Recaptcha.verify(token)
    end

    test "handles network errors" do
      expect(HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:error, %RuntimeError{message: "Network error"}}
      end)

      assert {:error, :recaptcha_network_error} = Recaptcha.verify("token")
    end
  end

  describe "maybe_put_remote_ip/2" do
    test "adds remoteip when valid IPv4" do
      params = %{"foo" => "bar"}

      assert %{"foo" => "bar", "remoteip" => "1.2.3.4"} =
               Recaptcha.maybe_put_remote_ip(params, "1.2.3.4")
    end

    test "adds remoteip when valid IPv6" do
      params = %{"foo" => "bar"}

      assert %{"foo" => "bar", "remoteip" => "2001:0db8:85a3:0000:0000:8a2e:0370:7334"} =
               Recaptcha.maybe_put_remote_ip(params, "2001:0db8:85a3:0000:0000:8a2e:0370:7334")
    end

    test "does not add remoteip when invalid or blank" do
      params = %{"foo" => "bar"}
      assert ^params = Recaptcha.maybe_put_remote_ip(params, "")
      assert ^params = Recaptcha.maybe_put_remote_ip(params, "invalid")
      assert ^params = Recaptcha.maybe_put_remote_ip(params, "unknown")
      # Scope ID rejected
      assert ^params = Recaptcha.maybe_put_remote_ip(params, "fe80::1%eth0")
    end

    test "does not add remoteip when string is too large" do
      params = %{"foo" => "bar"}
      large_ip = String.duplicate("a", 101)
      assert ^params = Recaptcha.maybe_put_remote_ip(params, large_ip)
    end
  end

  describe "validation helpers" do
    test "validate_min_score/2" do
      assert :ok = Recaptcha.validate_min_score(0.5, 0.4)
      assert {:error, :recaptcha_score_too_low} = Recaptcha.validate_min_score(0.3, 0.4)

      assert {:error, :recaptcha_invalid_score} =
               Recaptcha.validate_min_score("not a number", 0.4)

      assert {:error, :recaptcha_configuration_error} =
               Recaptcha.validate_min_score(0.5, "not a number")
    end
  end
end
