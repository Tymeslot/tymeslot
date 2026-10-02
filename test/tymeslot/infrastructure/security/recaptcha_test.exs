defmodule Tymeslot.Infrastructure.Security.RecaptchaTest do
  use Tymeslot.DataCase, async: false

  @moduletag :infrastructure

  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Infrastructure.Security.Recaptcha
  alias Tymeslot.Test.LogCapture
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

    test "reports an empty or nil token as missing, without calling Google" do
      assert {:error, :missing_token} = Recaptcha.verify("")
      assert {:error, :missing_token} = Recaptcha.verify(nil)
    end

    test "reports a non-binary token as invalid" do
      assert {:error, :invalid_token} = Recaptcha.verify(123)
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

  describe "siteverify request" do
    test "sends only the secret and the token, never the visitor's IP address" do
      test_pid = self()

      expect(HTTPClientMock, :post, fn _url, body, _headers, _opts ->
        send(test_pid, {:siteverify_body, body})

        {:ok,
         %Req.Response{status: 200, body: Jason.encode!(%{"success" => true, "score" => 0.9})}}
      end)

      assert {:ok, _details} = Recaptcha.verify("token")

      assert_received {:siteverify_body, body}
      assert URI.decode_query(body) == %{"secret" => "test_secret", "response" => "token"}
    end
  end

  describe "score logging" do
    setup do
      LogCapture.attach(logger_level: :info)
      :ok
    end

    defp stub_scored_response(score) do
      body = Jason.encode!(%{"success" => true, "score" => score, "action" => "booking_form"})

      expect(HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: body}}
      end)
    end

    test "logs the score and a passed outcome" do
      stub_scored_response(0.7)

      assert {:ok, _details} = Recaptcha.verify("token", min_score: 0.3)

      meta = LogCapture.user_metadata(LogCapture.await_log("reCAPTCHA verification scored"))

      assert %{
               event: "recaptcha_verification",
               outcome: :passed,
               score: 0.7,
               threshold: 0.3,
               action: "booking_form"
             } = meta
    end

    test "logs the score and the rejection reason when the score is too low" do
      stub_scored_response(0.1)

      assert {:error, :recaptcha_score_too_low} = Recaptcha.verify("token", min_score: 0.3)

      meta = LogCapture.user_metadata(LogCapture.await_log("reCAPTCHA verification scored"))

      assert %{outcome: :recaptcha_score_too_low, score: 0.1, threshold: 0.3} = meta
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

    test "validate_expected_action/2" do
      assert :ok = Recaptcha.validate_expected_action("signup_form", "signup_form")
      assert :ok = Recaptcha.validate_expected_action("anything", nil)

      assert {:error, :recaptcha_action_mismatch} =
               Recaptcha.validate_expected_action("login_form", "signup_form")

      # A missing action field (nil) is reported distinctly from a mismatch.
      assert {:error, :recaptcha_missing_action} =
               Recaptcha.validate_expected_action(nil, "signup_form")
    end

    test "validate_expected_hostname/2" do
      assert :ok = Recaptcha.validate_expected_hostname("example.com", [])
      assert :ok = Recaptcha.validate_expected_hostname("example.com", ["example.com"])

      assert {:error, :recaptcha_hostname_mismatch} =
               Recaptcha.validate_expected_hostname("evil.com", ["example.com"])

      # A missing hostname field (nil) is reported distinctly from a mismatch.
      assert {:error, :recaptcha_missing_hostname} =
               Recaptcha.validate_expected_hostname(nil, ["example.com"])
    end
  end
end
