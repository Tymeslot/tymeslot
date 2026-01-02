defmodule TymeslotWeb.Live.Scheduling.Handlers.FormValidationHandlerComponent do
  @moduledoc """
  Specialized handler for form validation operations in scheduling themes.

  This handler provides common form validation functionality that can be used across
  different themes, eliminating code duplication while maintaining theme independence.

  ## Usage

      alias TymeslotWeb.Live.Scheduling.Handlers.FormValidationHandlerComponent

      # In your theme's handle_info callback:
      def handle_info({:step_event, :booking, :validate, data}, socket) do
        case FormValidationHandlerComponent.validate_form(socket, data) do
          {:ok, updated_socket} -> {:noreply, updated_socket}
          {:error, error_socket} -> {:noreply, error_socket}
        end
      end

  ## Available Functions

  - `validate_form/2` - Validate booking form data
  - `sanitize_params/2` - Sanitize form parameters
  - `assign_form_errors/2` - Assign validation errors to socket
  - `mark_field_touched/2` - Mark a field as touched for validation
  """

  import Phoenix.Component, only: [assign: 3]

  alias Phoenix.Component
  alias Tymeslot.Security.FormValidation
  alias TymeslotWeb.Live.Scheduling.Helpers

  @doc """
  Validates booking form data and updates socket state.

  This function:
  1. Validates the form data using the security module
  2. Updates the form state with sanitized data
  3. Assigns validation errors if any

  ## Examples

      case FormValidationHandlerComponent.validate_form(socket, booking_params) do
        {:ok, updated_socket} -> {:noreply, updated_socket}
        {:error, error_socket} -> {:noreply, error_socket}
      end
  """
  @spec validate_form(Phoenix.LiveView.Socket.t(), map()) ::
          {:ok, Phoenix.LiveView.Socket.t()} | {:error, Phoenix.LiveView.Socket.t()}
  def validate_form(socket, booking_params) do
    case FormValidation.validate_booking_form(booking_params) do
      {:ok, sanitized_params} ->
        form = Component.to_form(sanitized_params)

        socket =
          socket
          |> assign(:form, form)
          |> assign(:validation_errors, [])

        {:ok, socket}

      {:error, errors} ->
        {:ok, sanitized_params} = FormValidation.sanitize_booking_params(booking_params)
        form = Component.to_form(sanitized_params)

        socket =
          socket
          |> assign(:form, form)
          |> Helpers.assign_form_errors(errors)

        {:error, socket}
    end
  end

  @doc """
  Sanitizes form parameters without validation.

  This function cleans the form parameters and returns sanitized data.

  ## Examples

      case FormValidationHandlerComponent.sanitize_params(socket, params) do
        {:ok, sanitized_params} -> # Use sanitized data
        {:error, reason} -> # Handle error
      end
  """
  @spec sanitize_params(Phoenix.LiveView.Socket.t(), map()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def sanitize_params(socket, params) do
    {:ok, sanitized_params} = FormValidation.sanitize_booking_params(params)
    form = Component.to_form(sanitized_params)
    socket = assign(socket, :form, form)
    {:ok, socket}
  end

  @doc """
  Assigns validation errors to the socket.

  This function takes a list of validation errors and assigns them to the socket
  for display in the UI.

  ## Examples

      socket = FormValidationHandlerComponent.assign_form_errors(socket, [
        {:name, "Name is required"},
        {:email, "Invalid email format"}
      ])
  """
  @spec assign_form_errors(Phoenix.LiveView.Socket.t(), list()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def assign_form_errors(socket, errors) do
    socket = Helpers.assign_form_errors(socket, errors)
    {:ok, socket}
  end

  @doc """
  Marks a field as touched for validation purposes.

  This function updates the field's touched state, which is used to determine
  when to show validation errors.

  ## Examples

      socket = FormValidationHandlerComponent.mark_field_touched(socket, "email")
  """
  @spec mark_field_touched(Phoenix.LiveView.Socket.t(), String.t()) ::
          {:ok, Phoenix.LiveView.Socket.t()}
  def mark_field_touched(socket, field_name) do
    socket = Helpers.mark_field_touched(socket, field_name)
    {:ok, socket}
  end

  @doc """
  Validates a specific field in the form.

  This function validates a single field and updates the socket with
  field-specific errors.

  ## Examples

      case FormValidationHandlerComponent.validate_field(socket, "email", "invalid-email") do
        {:ok, socket} -> # Field is valid
        {:error, socket} -> # Field has errors
      end
  """
  @spec validate_field(Phoenix.LiveView.Socket.t(), String.t(), any()) ::
          {:ok, Phoenix.LiveView.Socket.t()} | {:error, Phoenix.LiveView.Socket.t()}
  def validate_field(socket, field_name, field_value) do
    # Simple field validation - can be extended based on field type
    case {field_name, field_value} do
      {"email", value} when is_binary(value) ->
        if String.contains?(value, "@") do
          clear_field_error(socket, field_name)
        else
          add_field_error(socket, field_name, "Invalid email format")
        end

      {"name", value} when is_binary(value) ->
        if String.trim(value) != "" do
          clear_field_error(socket, field_name)
        else
          add_field_error(socket, field_name, "Name is required")
        end

      {_field, _value} ->
        # For other fields, assume valid
        clear_field_error(socket, field_name)
    end
  end

  defp clear_field_error(socket, field_name) do
    current_errors = socket.assigns[:validation_errors] || []
    updated_errors = Enum.reject(current_errors, fn {field, _} -> field == field_name end)

    socket = assign(socket, :validation_errors, updated_errors)
    {:ok, socket}
  end

  defp add_field_error(socket, field_name, error_message) do
    current_errors = socket.assigns[:validation_errors] || []
    updated_errors = [{field_name, error_message} | current_errors]

    socket = assign(socket, :validation_errors, updated_errors)
    {:error, socket}
  end
end
