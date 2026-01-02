defmodule TymeslotWeb.Live.Scheduling.Handlers do
  @moduledoc """
  Specialized handlers for common scheduling functionality.

  This module provides documentation and convenience functions for accessing
  the various specialized handlers that can be used in scheduling themes.

  ## Available Handlers

  ### TimezoneHandlerComponent
  Handles timezone-related operations including changes, search, and dropdown management.

  **Functions:**
  - `handle_timezone_change/2` - Process timezone updates and reload slots
  - `handle_timezone_search/2` - Filter timezone search results  
  - `handle_timezone_dropdown_toggle/1` - Toggle dropdown state
  - `handle_timezone_dropdown_close/1` - Close dropdown

  ### SlotFetchingHandlerComponent
  Handles available time slot fetching and calendar integration.

  **Functions:**
  - `fetch_available_slots/4` - Fetch available time slots for a given date
  - `maybe_reload_slots/1` - Conditionally reload slots if date is selected
  - `handle_calendar_error/2` - Process calendar errors gracefully
  - `load_slots/2` - Load slots for a specific date

  ### FormValidationHandlerComponent
  Handles form validation, sanitization, and error management.

  **Functions:**
  - `validate_form/2` - Validate booking form data
  - `sanitize_params/2` - Sanitize form parameters
  - `assign_form_errors/2` - Assign validation errors to socket
  - `mark_field_touched/2` - Mark a field as touched for validation
  - `validate_field/3` - Validate a specific field

  ### BookingSubmissionHandlerComponent
  Handles booking submission, orchestration, and success/error handling.

  **Functions:**
  - `submit_booking/2` - Process booking submission with orchestrator
  - `handle_booking_success/3` - Handle successful booking creation
  - `handle_booking_error/2` - Handle booking submission errors
  - `check_duplicate_submission/1` - Check for duplicate submissions

  ## Usage Pattern

  Handlers are designed to be used as pure functions that return `{:ok, socket}` 
  or `{:error, socket}` tuples. They can be chained together or used independently.

  ### Basic Usage

      alias TymeslotWeb.Live.Scheduling.Handlers.TimezoneHandlerComponent

      def handle_info({:step_event, :schedule, :change_timezone, data}, socket) do
        case TimezoneHandlerComponent.handle_timezone_change(socket, data) do
          {:ok, updated_socket} -> {:noreply, updated_socket}
          {:error, error_socket} -> {:noreply, error_socket}
        end
      end

  ### Chaining Handlers

      alias TymeslotWeb.Live.Scheduling.Handlers.{
        FormValidationHandlerComponent,
        BookingSubmissionHandlerComponent
      }

      def handle_info({:step_event, :booking, :submit, data}, socket) do
        with {:ok, socket} <- FormValidationHandlerComponent.validate_form(socket, data),
             {:ok, socket} <- BookingSubmissionHandlerComponent.submit_booking(socket, data) do
          {:noreply, socket}
        else
          {:error, socket} -> {:noreply, socket}
        end
      end

  ### Multiple Handler Imports

      alias TymeslotWeb.Live.Scheduling.Handlers.{
        TimezoneHandlerComponent,
        SlotFetchingHandlerComponent,
        FormValidationHandlerComponent,
        BookingSubmissionHandlerComponent
      }

  ## Theme Integration

  Handlers are designed to work seamlessly with the existing theme system.
  They do not interfere with theme independence and can be used selectively.

  ### Selective Usage

  Themes can choose which handlers to use and can override handler behavior
  by implementing custom logic instead of or alongside the handlers.

      # Use handler for most timezone changes
      def handle_info({:step_event, :schedule, :change_timezone, data}, socket) do
        case TimezoneHandlerComponent.handle_timezone_change(socket, data) do
          {:ok, socket} -> {:noreply, socket}
          {:error, socket} -> {:noreply, socket}
        end
      end

      # Custom handling for theme-specific timezone behavior
      def handle_info({:step_event, :schedule, :glassmorphism_timezone, data}, socket) do
        socket = 
          socket
          |> assign(:glassmorphism_level, data.level)
          |> assign(:user_timezone, data.timezone)
        
        {:noreply, socket}
      end

  ### Override Capability

  Themes can override handler behavior by implementing their own versions
  of the functionality while still using handlers for other operations.

  ## Error Handling

  All handlers follow a consistent error handling pattern:

  - Return `{:ok, socket}` for successful operations
  - Return `{:error, socket}` for failed operations
  - Include appropriate flash messages for user feedback
  - Log errors for debugging purposes

  ## Testing

  Handlers can be tested independently as pure functions:

      test "timezone change updates socket state" do
        socket = %Phoenix.LiveView.Socket{assigns: %{user_timezone: "UTC"}}
        
        {:ok, updated_socket} = TimezoneHandlerComponent.handle_timezone_change(
          socket, 
          "America/New_York"
        )
        
        assert updated_socket.assigns.user_timezone == "America/New_York"
      end

  ## Performance Considerations

  Handlers are implemented as pure functions with minimal overhead:

  - No additional processes or GenServers
  - Direct function calls with no message passing
  - Shared state through socket assigns
  - Minimal memory footprint

  ## Migration Guide

  To migrate existing theme code to use handlers:

  1. **Identify common functionality** in your theme that matches handler capabilities
  2. **Import the relevant handlers** at the top of your theme module
  3. **Replace existing code** with handler function calls
  4. **Test the integration** to ensure functionality is preserved
  5. **Update any custom logic** that depends on the replaced code

  ## Future Handlers

  Additional handlers can be added to cover other common functionality:

  - `CalendarIntegrationHandlerComponent` - Calendar sync and management
  - `NotificationHandlerComponent` - Email and SMS notifications
  - `AnalyticsHandlerComponent` - Event tracking and metrics
  - `SecurityHandlerComponent` - Rate limiting and abuse protection
  """

  # Convenience aliases for all handlers
  alias TymeslotWeb.Live.Scheduling.Handlers.{
    BookingSubmissionHandlerComponent,
    FormValidationHandlerComponent,
    SlotFetchingHandlerComponent,
    TimezoneHandlerComponent
  }

  @doc """
  Returns a list of all available handlers with their descriptions.
  """
  @spec available_handlers() :: [map()]
  def available_handlers do
    [
      %{
        module: TimezoneHandlerComponent,
        name: "Timezone Handler",
        description: "Handles timezone changes, search, and dropdown management",
        functions: [
          :handle_timezone_change,
          :handle_timezone_search,
          :handle_timezone_dropdown_toggle,
          :handle_timezone_dropdown_close
        ]
      },
      %{
        module: SlotFetchingHandlerComponent,
        name: "Slot Fetching Handler",
        description: "Handles available time slot fetching and calendar integration",
        functions: [
          :fetch_available_slots,
          :maybe_reload_slots,
          :handle_calendar_error,
          :load_slots
        ]
      },
      %{
        module: FormValidationHandlerComponent,
        name: "Form Validation Handler",
        description: "Handles form validation, sanitization, and error management",
        functions: [
          :validate_form,
          :sanitize_params,
          :assign_form_errors,
          :mark_field_touched,
          :validate_field
        ]
      },
      %{
        module: BookingSubmissionHandlerComponent,
        name: "Booking Submission Handler",
        description: "Handles booking submission, orchestration, and success/error handling",
        functions: [
          :submit_booking,
          :handle_booking_success,
          :handle_booking_error,
          :check_duplicate_submission
        ]
      }
    ]
  end

  @doc """
  Validates that all handlers are properly loaded and available.
  """
  @spec validate_handlers() :: :ok | {:error, list()}
  def validate_handlers do
    results =
      Enum.map(available_handlers(), fn handler ->
        case Code.ensure_loaded(handler.module) do
          {:module, _} -> {handler.name, :ok}
          {:error, reason} -> {handler.name, {:error, reason}}
        end
      end)

    failed_handlers = Enum.filter(results, fn {_name, result} -> result != :ok end)

    if Enum.empty?(failed_handlers) do
      :ok
    else
      {:error, failed_handlers}
    end
  end
end
