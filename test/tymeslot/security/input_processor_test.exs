defmodule Tymeslot.Security.InputProcessorTest do
  use ExUnit.Case, async: true
  @moduletag :security

  import ExUnit.CaptureLog

  alias Tymeslot.Security.InputProcessor

  defmodule AlwaysOkValidator do
    @spec validate(any()) :: :ok
    def validate(_value), do: :ok

    @spec validate(any(), keyword()) :: :ok
    def validate(_value, _opts), do: :ok
  end

  test "validate_form/3 does not create atoms from unexpected string field_specs" do
    field_name = "unexpected_field_#{System.unique_integer([:positive])}"

    assert_raise ArgumentError, fn -> String.to_existing_atom(field_name) end

    assert {:ok, _result} =
             InputProcessor.validate_form(
               %{field_name => "value"},
               [{field_name, AlwaysOkValidator}],
               metadata: %{},
               universal_opts: [log_events: false]
             )

    assert_raise ArgumentError, fn -> String.to_existing_atom(field_name) end
  end

  describe "type-dispatch via atoms" do
    test "resolves :email type to EmailValidator" do
      assert {:ok, _result} =
               InputProcessor.validate_form(
                 %{"email" => "user@example.com"},
                 [{"email", :email}]
               )

      assert {:error, errors} =
               InputProcessor.validate_form(
                 %{"email" => "not-an-email"},
                 [{"email", :email}]
               )

      assert Map.has_key?(errors, :email)
    end

    test "resolves :name type to NameValidator" do
      assert {:ok, _result} =
               InputProcessor.validate_form(
                 %{"name" => "John Smith"},
                 [{"name", :name}]
               )

      assert {:error, errors} =
               InputProcessor.validate_form(
                 %{"name" => ""},
                 [{"name", :name}]
               )

      assert Map.has_key?(errors, :name)
    end

    test "resolves :message type with per-field opts" do
      # With required: false, empty message is allowed
      assert {:ok, _result} =
               InputProcessor.validate_form(
                 %{"message" => ""},
                 [{"message", :message, [required: false, min_length: 0]}]
               )

      # Without opts, empty message is rejected
      assert {:error, errors} =
               InputProcessor.validate_form(
                 %{"message" => ""},
                 [{"message", :message}]
               )

      assert Map.has_key?(errors, :message)
    end

    test "validate_field/2 accepts type atom" do
      assert {:ok, _result} = InputProcessor.validate_field("user@example.com", :email)
      assert {:error, _error} = InputProcessor.validate_field("not-an-email", :email)
    end
  end

  # Regression guard: a phx-change-driven LiveView form flooded the security log
  # with one "Validation failure" entry per keystroke because every business-rule
  # failure (required / length / format) was routed through SecurityLogger.
  # Business-rule validation outcomes are UX signals, not security events, and
  # must not reach the security log. Sanitiser-triggered events (SQL injection,
  # path traversal, oversize input, invalid encoding) are logged separately by
  # UniversalSanitizer and are covered in universal_sanitizer_test.exs.
  describe "does not emit security log lines for business-rule failures" do
    test "validate_form/3 with a required-field failure produces no log output" do
      log =
        capture_log(fn ->
          assert {:error, %{username: _reason}} =
                   InputProcessor.validate_form(
                     %{"username" => ""},
                     [{"username", :username}]
                   )
        end)

      refute log =~ "Validation failure"
      refute log =~ "Validation successful"
    end

    test "validate_form/3 with a format failure produces no log output" do
      log =
        capture_log(fn ->
          assert {:error, %{username: _reason}} =
                   InputProcessor.validate_form(
                     %{"username" => "_bad start"},
                     [{"username", :username}]
                   )
        end)

      refute log =~ "Validation failure"
      refute log =~ "Validation successful"
    end

    test "validate_form/3 on the happy path produces no log output" do
      log =
        capture_log(fn ->
          assert {:ok, _result} =
                   InputProcessor.validate_form(
                     %{"email" => "user@example.com"},
                     [{"email", :email}]
                   )
        end)

      refute log =~ "Validation failure"
      refute log =~ "Validation successful"
    end

    test "validate_field/3 with a business-rule failure produces no log output" do
      log =
        capture_log(fn ->
          assert {:error, _reason} = InputProcessor.validate_field("ab", :username)
        end)

      refute log =~ "Validation failure"
      refute log =~ "Validation successful"
    end
  end

  describe "skip-sanitisation keys" do
    # reCAPTCHA tokens are opaque, high-entropy strings issued by Google.
    # Their byte sequences can incidentally match SQL/path-traversal heuristics,
    # so they must bypass the universal sanitiser and be returned to callers
    # unchanged for forwarding to the external siteverify API.
    @recaptcha_like_token "03AGdBq27--very-long-opaque-token-with/slashes/and=equals"

    test "validate_form/3 does not sanitise 'g-recaptcha-response'" do
      params = %{
        "email" => "user@example.com",
        "g-recaptcha-response" => @recaptcha_like_token
      }

      assert {:ok, result} =
               InputProcessor.validate_form(params, [{"email", :email}],
                 universal_opts: [log_events: false]
               )

      assert result["g-recaptcha-response"] == @recaptcha_like_token
    end

    test "validate_form/3 preserves 'g-recaptcha-response' value in returned params" do
      token = "some-recaptcha-token-value"

      params = %{"email" => "user@example.com", "g-recaptcha-response" => token}

      assert {:ok, result} = InputProcessor.validate_form(params, [{"email", :email}])

      assert Map.has_key?(result, "g-recaptcha-response")
      assert result["g-recaptcha-response"] == token
    end

    test "validate_form/3 still sanitises non-skip fields with the same content" do
      # A field that is NOT in the skip list and contains a path-traversal-like
      # string should be rejected by the sanitiser, proving the skip is specific
      # to the listed keys and not a general bypass.
      #
      # Error path: validate_form short-circuits in the sanitiser before the
      # skip list is merged back, so only the :name error is observable here.
      error_params = %{
        "name" => "../../etc/passwd",
        "g-recaptcha-response" => "../../etc/passwd"
      }

      assert {:error, errors} =
               InputProcessor.validate_form(error_params, [{"name", :name}],
                 universal_opts: [log_events: false]
               )

      assert Map.has_key?(errors, :name)

      # Happy path: a benign name alongside the same suspicious reCAPTCHA
      # content confirms the skip is field-specific — the token is returned
      # unchanged even though it would have been rejected if it had appeared
      # in a non-skipped field.
      ok_params = %{
        "name" => "Alice",
        "g-recaptcha-response" => "../../etc/passwd"
      }

      assert {:ok, result} =
               InputProcessor.validate_form(ok_params, [{"name", :name}],
                 universal_opts: [log_events: false]
               )

      assert result["g-recaptcha-response"] == "../../etc/passwd"
    end
  end
end
