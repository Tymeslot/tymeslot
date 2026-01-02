defmodule Tymeslot.Infrastructure.ValidationHelpers do
  @moduledoc """
  Generic validation utilities for Phoenix applications.

  This module provides reusable validation helpers that can be used
  across different bounded contexts in the application.
  """

  require Logger
  alias Phoenix.Component
  alias Phoenix.LiveView.Socket
  alias Plug.Conn

  @doc """
  Validates input and executes success or error callbacks.

  This wrapper reduces the common pattern of validating input and branching
  on success or error.

  ## Parameters
  - params: The parameters to validate
  - validation_fun: Function that validates the params, returns {:ok, validated} or {:error, errors}
  - success_fun: Function to call with validated params on success
  - error_fun: Function to call with errors on validation failure

  ## Examples

      with_validation(params, &Validation.validate_login_input/1,
        fn validated_params ->
          # Handle success
          {:ok, validated_params}
        end,
        fn errors ->
          # Handle errors
          {:error, format_errors(errors)}
        end
      )
  """
  @spec with_validation(map(), function(), function(), function()) :: any()
  def with_validation(params, validation_fun, success_fun, error_fun) do
    case validation_fun.(params) do
      {:ok, validated_params} ->
        success_fun.(validated_params)

      {:error, errors} ->
        error_fun.(errors)
    end
  end

  @doc """
  Validates input and updates socket/conn state.

  Specialized version of with_validation for LiveView/Controller contexts
  where you need to update assigns on validation.

  ## Parameters
  - socket_or_conn: Phoenix.LiveView.Socket or Plug.Conn
  - params: Parameters to validate
  - validation_fun: Validation function
  - opts: Options including:
    - :form_data_key - Key to store form data under (default: :form_data)
    - :errors_key - Key to store errors under (default: :errors)

  ## Returns
  Updated socket/conn with either cleared errors or validation errors
  """
  @spec validate_and_assign(
          Phoenix.LiveView.Socket.t() | Plug.Conn.t(),
          map(),
          function(),
          keyword()
        ) :: Phoenix.LiveView.Socket.t() | Plug.Conn.t()
  def validate_and_assign(socket_or_conn, params, validation_fun, opts \\ []) do
    form_data_key = Keyword.get(opts, :form_data_key, :form_data)
    errors_key = Keyword.get(opts, :errors_key, :errors)

    case validation_fun.(params) do
      {:ok, _validated_params} ->
        socket_or_conn
        |> assign_or_put(errors_key, %{})
        |> assign_or_put(form_data_key, params)

      {:error, errors} ->
        socket_or_conn
        |> assign_or_put(errors_key, errors)
        |> assign_or_put(form_data_key, params)
    end
  end

  @doc """
  Validates required fields in a parameter map.

  ## Parameters
  - params: Map of parameters to validate
  - required_fields: List of required field names (as strings)

  ## Returns
  - {:ok, params} if all required fields are present and non-empty
  - {:error, errors} with a map of missing fields

  ## Examples

      validate_required_fields(%{"email" => "test@example.com"}, ["email", "password"])
      # => {:error, %{password: ["can't be blank"]}}
  """
  @spec validate_required_fields(map(), list(String.t())) ::
          {:ok, map()} | {:error, map()}
  def validate_required_fields(params, required_fields) do
    errors =
      required_fields
      |> Enum.filter(fn field ->
        value = Map.get(params, field)
        is_nil(value) or value == ""
      end)
      |> Enum.map(fn field ->
        {String.to_existing_atom(field), ["can't be blank"]}
      end)
      |> Enum.into(%{})

    if map_size(errors) == 0 do
      {:ok, params}
    else
      {:error, errors}
    end
  end

  @doc """
  Chains multiple validation functions together.

  Runs validations in sequence, stopping at the first error.

  ## Parameters
  - params: Parameters to validate
  - validations: List of validation functions

  ## Returns
  - {:ok, params} if all validations pass
  - {:error, errors} from the first failing validation

  ## Examples

      chain_validations(params, [
        &validate_required_fields(&1, ["email", "password"]),
        &Validation.validate_email/1,
        &Validation.validate_password/1
      ])
  """
  @spec chain_validations(map(), list(function())) ::
          {:ok, map()} | {:error, any()}
  def chain_validations(params, validations) do
    Enum.reduce_while(validations, {:ok, params}, fn validation_fun, {:ok, current_params} ->
      case validation_fun.(current_params) do
        {:ok, updated_params} -> {:cont, {:ok, updated_params}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # Private helpers

  defp assign_or_put(socket_or_conn, key, value) do
    case socket_or_conn do
      %Socket{} = socket ->
        Component.assign(socket, key, value)

      %Conn{} = conn ->
        Conn.assign(conn, key, value)
    end
  end
end
