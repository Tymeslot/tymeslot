defmodule Tymeslot.Security.InputProcessor do
  @moduledoc """
  Main entry point for input validation and sanitization.

  Provides a clean API for validating forms with universal sanitization
  followed by field-specific validation with error aggregation.
  """

  alias Tymeslot.Security.{SecurityLogger, UniversalSanitizer}

  @doc """
  Validates a form with universal sanitization and field-specific validation.

  ## Parameters
  - `params` - Form parameters (map with string keys)
  - `field_specs` - List of {field_name, validator_module} tuples
  - `opts` - Options for validation

  ## Options
  - `:metadata` - Metadata for logging (ip, user_id, etc.)
  - `:universal_opts` - Options passed to universal sanitizer

  ## Examples

      InputProcessor.validate_form(params, [
        {"email", EmailValidator},
        {"name", NameValidator},
        {"message", MessageValidator}
      ])

      # Returns:
      {:ok, %{"email" => "user@example.com", "name" => "John", "message" => "Hello"}}
      # or
      {:error, %{email: "Email format is invalid", name: "Name is required"}}
  """
  @spec validate_form(map(), list(), keyword()) :: {:ok, map()} | {:error, map()}
  def validate_form(params, field_specs, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})
    universal_opts = Keyword.get(opts, :universal_opts, [])

    # Step 1: Universal sanitization for all fields
    with {:ok, sanitized_params} <- sanitize_all_fields(params, universal_opts, metadata) do
      # Step 2: Field-specific validation with error aggregation
      validate_fields_with_aggregation(sanitized_params, field_specs, metadata)
    end
  end

  @doc """
  Validates a single field with universal sanitization and specific validation.

  ## Examples

      InputProcessor.validate_field("user@example.com", EmailValidator)
      # Returns: {:ok, "user@example.com"}

      InputProcessor.validate_field("<script>alert(1)</script>", EmailValidator)
      # Returns: {:error, "Email format is invalid (missing @ symbol)"}
  """
  @spec validate_field(any(), module(), keyword()) :: {:ok, any()} | {:error, String.t()}
  def validate_field(value, validator_module, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})
    universal_opts = Keyword.get(opts, :universal_opts, [])

    with {:ok, sanitized} <- UniversalSanitizer.sanitize_and_validate(value, universal_opts),
         :ok <- validator_module.validate(sanitized, opts) do
      SecurityLogger.log_successful_validation(:single_field, metadata)
      {:ok, sanitized}
    else
      {:error, reason} ->
        SecurityLogger.log_validation_failure(:single_field, reason, metadata)
        {:error, reason}
    end
  end

  # Private functions

  defp sanitize_all_fields(params, universal_opts, metadata) when is_map(params) do
    sanitization_opts = Keyword.merge(universal_opts, metadata: metadata)

    Enum.reduce_while(params, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case UniversalSanitizer.sanitize_and_validate(value, sanitization_opts) do
        {:ok, sanitized_value} ->
          {:cont, {:ok, Map.put(acc, key, sanitized_value)}}

        {:error, reason} ->
          field_key = safe_field_key(key)
          SecurityLogger.log_validation_failure(field_key, reason, metadata)
          {:halt, {:error, %{field_key => reason}}}
      end
    end)
  end

  defp safe_field_key(key) when is_atom(key), do: key

  defp safe_field_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp safe_field_key(key), do: key

  defp validate_fields_with_aggregation(sanitized_params, field_specs, metadata) do
    errors =
      Enum.reduce(field_specs, %{}, fn {field_name, validator_module}, acc ->
        field_key = safe_field_key(field_name)

        field_value =
          case field_name do
            name when is_atom(name) ->
              Map.get(sanitized_params, name) || Map.get(sanitized_params, Atom.to_string(name))

            name ->
              Map.get(sanitized_params, name)
          end

        case validator_module.validate(field_value) do
          :ok ->
            SecurityLogger.log_successful_validation(field_key, metadata)
            acc

          {:error, reason} ->
            SecurityLogger.log_validation_failure(field_key, reason, metadata)
            Map.put(acc, field_key, reason)
        end
      end)

    if map_size(errors) == 0 do
      {:ok, sanitized_params}
    else
      {:error, errors}
    end
  end
end
