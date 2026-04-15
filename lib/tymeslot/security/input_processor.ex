defmodule Tymeslot.Security.InputProcessor do
  @moduledoc """
  Main entry point for input validation and sanitization.

  Provides a clean API for validating forms with universal sanitization
  followed by field-specific validation with error aggregation.
  """

  alias Tymeslot.Security.{FieldValidators, SecurityLogger, UniversalSanitizer}

  @type form_params :: %{String.t() => term()}
  @type form_errors :: %{atom() => [String.t()]}

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
        {"email", :email},
        {"name", :name},
        {"message", :message, [required: false, min_length: 0]}
      ])

      # Also accepts explicit validator modules for backwards compatibility:
      InputProcessor.validate_form(params, [
        {"email", EmailValidator},
        {"name", NameValidator}
      ])

      # Returns:
      {:ok, %{"email" => "user@example.com", "name" => "John", "message" => "Hello"}}
      # or
      {:error, %{email: "Email format is invalid", name: "Name is required"}}
  """
  @spec validate_form(form_params(), list(), keyword()) ::
          {:ok, form_params()} | {:error, form_errors()}
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

  Accepts a type atom (`:email`, `:name`, `:password`, etc.) or an explicit
  validator module for backwards compatibility.

  ## Examples

      InputProcessor.validate_field("user@example.com", :email)
      # Returns: {:ok, "user@example.com"}

      InputProcessor.validate_field("<script>alert(1)</script>", :email)
      # Returns: {:error, "Email format is invalid (missing @ symbol)"}
  """
  @spec validate_field(any(), atom(), keyword()) :: {:ok, any()} | {:error, String.t()}
  def validate_field(value, type_or_module, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})
    universal_opts = Keyword.get(opts, :universal_opts, [])
    field = Keyword.get(opts, :field, type_or_module)
    validator_module = resolve_validator(type_or_module)

    universal_opts_with_field = Keyword.put(universal_opts, :field, field)

    with {:ok, sanitized} <-
           UniversalSanitizer.sanitize_and_validate(value, universal_opts_with_field),
         :ok <- validator_module.validate(sanitized, opts) do
      SecurityLogger.log_successful_validation(field, metadata)
      {:ok, sanitized}
    else
      {:error, reason} ->
        SecurityLogger.log_validation_failure(field, reason, metadata)
        {:error, reason}
    end
  end

  # Private functions

  defp sanitize_all_fields(params, universal_opts, metadata) when is_map(params) do
    base_opts = Keyword.merge(universal_opts, metadata: metadata)

    Enum.reduce_while(params, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      field_key = safe_field_key(key)
      opts_for_field = Keyword.put(base_opts, :field, field_key)

      case UniversalSanitizer.sanitize_and_validate(value, opts_for_field) do
        {:ok, sanitized_value} ->
          {:cont, {:ok, Map.put(acc, key, sanitized_value)}}

        {:error, reason} ->
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
      Enum.reduce(field_specs, %{}, fn spec, acc ->
        {field_name, type_or_module, field_opts} =
          case spec do
            {f, t, o} -> {f, t, o}
            {f, t} -> {f, t, []}
          end

        validator_module = resolve_validator(type_or_module)
        field_key = safe_field_key(field_name)

        field_value =
          case field_name do
            name when is_atom(name) ->
              Map.get(sanitized_params, name) || Map.get(sanitized_params, Atom.to_string(name))

            name ->
              Map.get(sanitized_params, name)
          end

        case validator_module.validate(field_value, field_opts) do
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

  defp resolve_validator(:email), do: FieldValidators.EmailValidator
  defp resolve_validator(:password), do: FieldValidators.PasswordValidator
  defp resolve_validator(:name), do: FieldValidators.NameValidator
  defp resolve_validator(:full_name), do: FieldValidators.FullNameValidator
  defp resolve_validator(:username), do: FieldValidators.UsernameValidator
  defp resolve_validator(:message), do: FieldValidators.MessageValidator
  defp resolve_validator(:text), do: FieldValidators.TextValidator
  defp resolve_validator(:integration_name), do: FieldValidators.IntegrationNameValidator
  defp resolve_validator(module) when is_atom(module), do: module
end
