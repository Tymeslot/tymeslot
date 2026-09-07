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
