defmodule Tymeslot.Integrations.Common.ConfigManager do
  @moduledoc """
  Centralized configuration management for integration providers.

  This module provides consistent configuration validation, normalization,
  and schema management across all integration providers.
  """

  @type config :: map()
  @type schema :: map()
  @type validation_result :: :ok | {:error, String.t()}

  @doc """
  Validates configuration against a schema.

  ## Schema Format

  Each field in the schema should be a map with the following keys:
  - `:type` - The expected type (`:string`, `:integer`, `:boolean`, `:datetime`, `:map`, `:list`)
  - `:required` - Whether the field is required (default: `false`)
  - `:default` - Default value if not provided (optional)
  - `:validator` - Custom validation function (optional)

  ## Examples

      schema = %{
        access_token: %{type: :string, required: true},
        timeout: %{type: :integer, default: 5000},
        enabled: %{type: :boolean, default: true}
      }

      validate_config(%{access_token: "token123"}, schema)
      # => :ok
  """
  @spec validate_config(config(), schema()) :: validation_result()
  def validate_config(config, schema) when is_map(config) and is_map(schema) do
    with :ok <- validate_required_fields(config, schema),
         :ok <- validate_field_types(config, schema) do
      validate_custom_validators(config, schema)
    end
  end

  @doc """
  Normalizes configuration by applying defaults and type coercion.

  ## Examples

      schema = %{
        timeout: %{type: :integer, default: 5000},
        retries: %{type: :integer, default: 3}
      }

      normalize_config(%{timeout: "1000"}, schema)
      # => {:ok, %{timeout: 1000, retries: 3}}
  """
  @spec normalize_config(config(), schema()) :: {:ok, config()} | {:error, String.t()}
  def normalize_config(config, schema) when is_map(config) and is_map(schema) do
    normalized =
      Enum.reduce(schema, config, fn {field, field_schema}, acc ->
        normalize_field(acc, field, field_schema)
      end)

    {:ok, normalized}
  rescue
    exception ->
      {:error, "Configuration normalization failed: #{Exception.message(exception)}"}
  end

  @doc """
  Validates and normalizes configuration in one step.

  ## Examples

      process_config(%{access_token: "token123"}, oauth_schema())
      # => {:ok, %{access_token: "token123", ...}}
  """
  @spec process_config(config(), schema()) :: {:ok, config()} | {:error, String.t()}
  def process_config(config, schema) do
    with {:ok, normalized_config} <- normalize_config(config, schema),
         :ok <- validate_config(normalized_config, schema) do
      {:ok, normalized_config}
    end
  end

  @doc """
  Returns the common OAuth configuration schema.
  """
  @spec oauth_schema() :: schema()
  def oauth_schema do
    %{
      access_token: %{type: :string, required: true},
      refresh_token: %{type: :string, required: true},
      token_expires_at: %{type: :datetime, required: true},
      oauth_scope: %{type: :string, required: true}
    }
  end

  @doc """
  Returns the common HTTP client configuration schema.
  """
  @spec http_client_schema() :: schema()
  def http_client_schema do
    %{
      timeout: %{type: :integer, default: 30_000},
      retries: %{type: :integer, default: 3},
      base_url: %{type: :string, required: true},
      headers: %{type: :map, default: %{}},
      follow_redirects: %{type: :boolean, default: true}
    }
  end

  @doc """
  Returns the common provider metadata schema.
  """
  @spec provider_metadata_schema() :: schema()
  def provider_metadata_schema do
    %{
      name: %{type: :string, required: true},
      display_name: %{type: :string, required: true},
      provider: %{type: :string, required: true},
      is_active: %{type: :boolean, default: true}
    }
  end

  @doc """
  Merges multiple schemas into a single schema.

  Later schemas override fields from earlier schemas.

  ## Examples

      merge_schemas([oauth_schema(), http_client_schema()])
  """
  @spec merge_schemas(list(schema())) :: schema()
  def merge_schemas(schemas) when is_list(schemas) do
    Enum.reduce(schemas, %{}, &Map.merge(&2, &1))
  end

  @doc """
  Extracts configuration for a specific provider from user settings.

  Handles the common pattern of retrieving provider-specific configuration
  from larger configuration maps.
  """
  @spec extract_provider_config(config(), String.t(), schema()) ::
          {:ok, config()} | {:error, String.t()}
  def extract_provider_config(user_config, provider_name, schema) do
    provider_config =
      user_config
      |> Map.get(:integrations, %{})
      |> Map.get(provider_name, %{})

    process_config(provider_config, schema)
  end

  @doc """
  Validates that sensitive configuration fields are properly encrypted.

  Checks that fields marked as `:encrypted` in the schema contain encrypted values.
  """
  @spec validate_encryption(config(), schema()) :: validation_result()
  def validate_encryption(config, schema) do
    encrypted_fields =
      schema
      |> Enum.filter(fn {_field, field_schema} ->
        Map.get(field_schema, :encrypted, false)
      end)
      |> Enum.map(fn {field, _schema} -> field end)

    unencrypted_fields =
      Enum.filter(encrypted_fields, fn field ->
        value = Map.get(config, field)
        value && is_binary(value) && not encrypted?(value)
      end)

    case unencrypted_fields do
      [] -> :ok
      fields -> {:error, "Unencrypted sensitive fields: #{Enum.join(fields, ", ")}"}
    end
  end

  # Private functions

  defp validate_required_fields(config, schema) do
    required_fields =
      schema
      |> Enum.filter(fn {_field, field_schema} ->
        Map.get(field_schema, :required, false)
      end)
      |> Enum.map(fn {field, _schema} -> field end)

    missing_fields =
      required_fields
      |> Enum.reject(&Map.has_key?(config, &1))
      |> Enum.map(&to_string/1)

    case missing_fields do
      [] -> :ok
      fields -> {:error, "Missing required fields: #{Enum.join(fields, ", ")}"}
    end
  end

  defp validate_field_types(config, schema) do
    type_errors =
      Enum.flat_map(config, fn {field, value} -> type_error_for_field(field, value, schema) end)

    case type_errors do
      [] -> :ok
      errors -> {:error, "Type validation failed: #{Enum.join(errors, ", ")}"}
    end
  end

  defp type_error_for_field(field, value, schema) do
    case Map.get(schema, field) do
      nil ->
        []

      field_schema ->
        expected_type = Map.get(field_schema, :type)

        if valid_type?(value, expected_type),
          do: [],
          else: ["#{field}: expected #{expected_type}, got #{actual_type(value)}"]
    end
  end

  defp validate_custom_validators(config, schema) do
    validation_errors =
      Enum.reduce(config, [], fn {field, value}, errors ->
        validate_field_with_custom_validator(field, value, schema, errors)
      end)

    case validation_errors do
      [] -> :ok
      errors -> {:error, "Validation failed: #{Enum.join(errors, ", ")}"}
    end
  end

  defp validate_field_with_custom_validator(field, value, schema, errors) do
    case Map.get(schema, field) do
      nil -> errors
      field_schema -> apply_custom_validator(field, value, field_schema, errors)
    end
  end

  defp apply_custom_validator(field, value, field_schema, errors) do
    case Map.get(field_schema, :validator) do
      nil ->
        errors

      validator_fn when is_function(validator_fn, 1) ->
        case validator_fn.(value) do
          :ok -> errors
          {:error, message} -> ["#{field}: #{message}" | errors]
        end
    end
  end

  defp normalize_field(config, field, field_schema) do
    current_value = Map.get(config, field)
    default_value = Map.get(field_schema, :default)
    field_type = Map.get(field_schema, :type)

    cond do
      current_value != nil ->
        Map.put(config, field, coerce_type(current_value, field_type))

      default_value != nil ->
        Map.put(config, field, default_value)

      true ->
        config
    end
  end

  defp valid_type?(value, :string), do: is_binary(value)
  defp valid_type?(value, :integer), do: is_integer(value)
  defp valid_type?(value, :boolean), do: is_boolean(value)
  defp valid_type?(value, :datetime), do: is_struct(value, DateTime)
  defp valid_type?(value, :map), do: is_map(value)
  defp valid_type?(value, :list), do: is_list(value)
  defp valid_type?(_value, _type), do: true

  defp actual_type(value) when is_binary(value), do: :string
  defp actual_type(value) when is_integer(value), do: :integer
  defp actual_type(value) when is_boolean(value), do: :boolean
  defp actual_type(%DateTime{}), do: :datetime
  defp actual_type(value) when is_map(value), do: :map
  defp actual_type(value) when is_list(value), do: :list
  defp actual_type(_value), do: :unknown

  defp coerce_type(value, :string) when is_binary(value), do: value
  defp coerce_type(value, :string), do: to_string(value)
  defp coerce_type(value, :integer) when is_integer(value), do: value

  defp coerce_type(value, :integer) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> value
    end
  end

  defp coerce_type(value, :boolean) when is_boolean(value), do: value
  defp coerce_type("true", :boolean), do: true
  defp coerce_type("false", :boolean), do: false
  defp coerce_type(value, _type), do: value

  defp encrypted?(value) when is_binary(value) do
    # Simple heuristic: encrypted values are typically base64 encoded and longer
    String.length(value) > 20 and String.match?(value, ~r/^[A-Za-z0-9+\/=]+$/)
  end

  defp encrypted?(_value), do: false
end
