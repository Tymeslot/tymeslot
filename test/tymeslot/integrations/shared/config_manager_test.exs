defmodule Tymeslot.Integrations.Common.ConfigManagerTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Common.ConfigManager

  describe "validate_config/2" do
    test "validates required fields" do
      schema = %{
        api_key: %{type: :string, required: true},
        base_url: %{type: :string, required: true},
        timeout: %{type: :integer, required: false}
      }

      assert :ok = ConfigManager.validate_config(%{api_key: "key", base_url: "url"}, schema)

      assert {:error, message} = ConfigManager.validate_config(%{api_key: "key"}, schema)
      assert String.contains?(message, "base_url")
    end

    test "validates field types" do
      schema = %{
        timeout: %{type: :integer, required: true}
      }

      assert :ok = ConfigManager.validate_config(%{timeout: 5000}, schema)

      assert {:error, message} = ConfigManager.validate_config(%{timeout: "5000"}, schema)
      assert String.contains?(message, "expected integer")
    end

    test "executes custom validators" do
      schema = %{
        url: %{
          type: :string,
          required: true,
          validator: fn val ->
            if String.starts_with?(val, "https://"), do: :ok, else: {:error, "must be https"}
          end
        }
      }

      assert :ok = ConfigManager.validate_config(%{url: "https://example.com"}, schema)

      assert {:error, message} =
               ConfigManager.validate_config(%{url: "http://example.com"}, schema)

      assert String.contains?(message, "must be https")
    end
  end

  describe "normalize_config/2" do
    test "applies default values" do
      schema = %{
        timeout: %{type: :integer, default: 3000},
        enabled: %{type: :boolean, default: true}
      }

      {:ok, normalized} = ConfigManager.normalize_config(%{}, schema)
      assert normalized.timeout == 3000
      assert normalized.enabled == true
    end

    test "coerces types" do
      schema = %{
        timeout: %{type: :integer},
        enabled: %{type: :boolean}
      }

      {:ok, normalized} =
        ConfigManager.normalize_config(%{timeout: "5000", enabled: "false"}, schema)

      assert normalized.timeout == 5000
      assert normalized.enabled == false
    end
  end

  describe "process_config/2" do
    test "normalizes and validates in one step" do
      schema = %{
        api_key: %{type: :string, required: true},
        timeout: %{type: :integer, default: 1000}
      }

      assert {:ok, config} = ConfigManager.process_config(%{api_key: "test"}, schema)
      assert config.api_key == "test"
      assert config.timeout == 1000
    end
  end

  describe "merge_schemas/1" do
    test "merges multiple schemas" do
      s1 = %{field1: %{type: :string}}
      s2 = %{field2: %{type: :integer}}

      merged = ConfigManager.merge_schemas([s1, s2])
      assert merged[:field1]
      assert merged[:field2]
    end
  end

  describe "extract_provider_config/3" do
    test "extracts and processes provider-specific config" do
      user_config = %{
        integrations: %{
          "google" => %{
            access_token: "abc",
            refresh_token: "def",
            token_expires_at: DateTime.utc_now(),
            oauth_scope: "scope"
          }
        }
      }

      assert {:ok, config} =
               ConfigManager.extract_provider_config(
                 user_config,
                 "google",
                 ConfigManager.oauth_schema()
               )

      assert config.access_token == "abc"
    end

    test "returns error if extraction fails validation" do
      user_config = %{integrations: %{"google" => %{}}}

      assert {:error, message} =
               ConfigManager.extract_provider_config(
                 user_config,
                 "google",
                 ConfigManager.oauth_schema()
               )

      assert String.contains?(message, "Missing required fields")
    end
  end

  describe "validate_encryption/2" do
    test "validates that encrypted fields contain encrypted values" do
      schema = %{
        api_secret: %{type: :string, encrypted: true}
      }

      # Encrypted value (matches heuristic with prefix)
      prefixed_val = "TYS.ENC:some-base64-data"
      assert :ok = ConfigManager.validate_encryption(%{api_secret: prefixed_val}, schema)

      # Encrypted value (matches heuristic with length)
      long_val = String.duplicate("A", 45)
      assert :ok = ConfigManager.validate_encryption(%{api_secret: long_val}, schema)

      # Unencrypted value
      assert {:error, message} =
               ConfigManager.validate_encryption(%{api_secret: "short-plain"}, schema)

      assert String.contains?(message, "Unencrypted sensitive fields: api_secret")
    end

    test "fails for 32-character hex string (heuristic edge case)" do
      schema = %{
        api_key: %{type: :string, encrypted: true}
      }

      # A 32-character hex string
      hex_key = "0123456789abcdef0123456789abcdef"

      # This should FAIL because it doesn't meet the new stricter heuristic
      assert {:error, message} = ConfigManager.validate_encryption(%{api_key: hex_key}, schema)
      assert String.contains?(message, "Unencrypted sensitive fields: api_key")
    end

    test "uses custom encryption validator if provided" do
      schema = %{
        api_secret: %{
          type: :string,
          encrypted: true,
          encryption_validator: fn val -> String.starts_with?(val, "TEST_ENC:") end
        }
      }

      assert :ok = ConfigManager.validate_encryption(%{api_secret: "TEST_ENC:data"}, schema)

      assert {:error, _error_message} =
               ConfigManager.validate_encryption(%{api_secret: "TYS.ENC:data"}, schema)
    end

    test "ignores non-encrypted fields" do
      schema = %{
        public_key: %{type: :string, encrypted: false}
      }

      assert :ok = ConfigManager.validate_encryption(%{public_key: "plain"}, schema)
    end
  end

  describe "type coercion edge cases" do
    test "coerces integer strings to integers" do
      schema = %{timeout: %{type: :integer}}
      {:ok, normalized} = ConfigManager.normalize_config(%{timeout: "123"}, schema)
      assert normalized.timeout == 123
    end

    test "returns original value if integer coercion fails" do
      schema = %{timeout: %{type: :integer}}
      {:ok, normalized} = ConfigManager.normalize_config(%{timeout: "abc"}, schema)
      assert normalized.timeout == "abc"
    end

    test "coerces boolean strings" do
      schema = %{enabled: %{type: :boolean}}
      {:ok, n1} = ConfigManager.normalize_config(%{enabled: "true"}, schema)
      assert n1.enabled == true

      {:ok, n2} = ConfigManager.normalize_config(%{enabled: "false"}, schema)
      assert n2.enabled == false
    end
  end
end
