defmodule Tymeslot.ConfigTestHelpers do
  @moduledoc """
  Helpers for temporarily modifying application configuration in tests.

  This module provides utilities to change application config for the duration
  of a test, with automatic restoration of original values on test exit.

  ## Why Use This?

  Instead of manually saving and restoring config (which is error-prone and verbose):

      test "with feature disabled" do
        previous = Application.get_env(:tymeslot, :feature_flag)
        Application.put_env(:tymeslot, :feature_flag, false)

        on_exit(fn ->
          Application.put_env(:tymeslot, :feature_flag, previous)
        end)

        # test logic
      end

  You can write:

      test "with feature disabled" do
        with_config(:tymeslot, feature_flag: false)
        # test logic - cleanup is automatic
      end

  ## Common Use Cases

  ### Testing with Feature Flags

      test "shows advanced features when enabled" do
        with_config(:tymeslot, advanced_features: true)
        # test with feature enabled
      end

  ### Testing Payment/Stripe Configuration

      test "validates webhook signature in production mode" do
        with_config(:tymeslot, [
          skip_webhook_verification: false,
          stripe_provider: Tymeslot.Payments.Stripe,
          stripe_webhook_secret: "whsec_test_secret"
        ])
        # test with real verification
      end

  ### Testing External Service Configuration

      test "uses custom API endpoint" do
        with_config(:tymeslot, [
          mirotalk_api_url: "https://custom.example.com",
          mirotalk_api_key: "test_key"
        ])
        # test with custom endpoint
      end

  ### In Setup Blocks

      setup do
        setup_config(:tymeslot, test_mode: true)
      end

  ## Important Notes

  - Changes are automatically reverted when the test exits (success or failure)
  - Original config values are preserved even if they were `nil` or not set
  - Works with both atom keys and nested config paths
  - Not safe in async tests (application env is global). Use `async: false`.
  """

  alias ExUnit.Callbacks

  @doc """
  Temporarily sets one or more config values for the current test.

  The config is automatically restored to its original value(s) when the test exits.

  ## Parameters

  - `app` - The application atom (e.g., `:tymeslot`, `:tymeslot_saas`)
  - `config` - Either a keyword list of config changes, or a single `{key, value}` pair

  ## Examples

      # Single config value
      with_config(:tymeslot, :feature_flag, false)

      # Multiple config values
      with_config(:tymeslot, [
        skip_webhook_verification: false,
        stripe_webhook_secret: "whsec_test",
        test_mode: true
      ])

      # Can be called multiple times in a test
      with_config(:tymeslot, logo_links_to_marketing: false)
      with_config(:tymeslot_saas, subscription_required: true)
  """
  @spec with_config(atom(), keyword()) :: :ok
  def with_config(app, config_list) when is_atom(app) and is_list(config_list) do
    # Save original values for all keys we're about to change
    original_values =
      Enum.map(config_list, fn {key, _value} ->
        {key, Application.fetch_env(app, key)}
      end)

    # Apply new config values
    Enum.each(config_list, fn {key, value} ->
      Application.put_env(app, key, value)
    end)

    # Register cleanup to restore original values
    Callbacks.on_exit(fn ->
      Enum.each(original_values, fn {key, original} ->
        case original do
          :error ->
            # If the key wasn't set before, delete it
            Application.delete_env(app, key)

          {:ok, value} ->
            # Restore the original value (including explicit nil)
            Application.put_env(app, key, value)
        end
      end)
    end)
  end

  @spec with_config(atom(), atom(), any()) :: :ok
  def with_config(app, key, value) when is_atom(app) and is_atom(key) do
    with_config(app, [{key, value}])
  end

  @doc """
  Setup helper for use in setup blocks.

  This is equivalent to `with_config/2` but returns `:ok` for convenient use
  in setup blocks.

  ## Examples

      setup do
        setup_config(:tymeslot, [
          logo_links_to_marketing: false,
          test_mode: true
        ])
      end

      setup do
        setup_config(:tymeslot, :feature_flag, true)
      end
  """
  @spec setup_config(atom(), keyword()) :: :ok
  def setup_config(app, config_list) when is_list(config_list) do
    with_config(app, config_list)
    :ok
  end

  @spec setup_config(atom(), atom(), any()) :: :ok
  def setup_config(app, key, value) when is_atom(key) do
    with_config(app, key, value)
    :ok
  end
end
