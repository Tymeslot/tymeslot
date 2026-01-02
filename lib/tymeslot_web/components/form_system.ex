defmodule TymeslotWeb.Components.FormSystem do
  @moduledoc """
  Unified form system providing consistent form components, validation, and error handling.
  Consolidates form logic from dashboard/form_helpers.ex, dashboard/settings_component.ex,
  and scheduling/helpers.ex into a single, reusable system.
  """

  use Phoenix.Component

  # ============================================================================
  # FORM STATE MANAGEMENT
  # ============================================================================

  @doc """
  Sets up form state with initial data and validation tracking.
  """
  @spec setup_form_state(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def setup_form_state(socket, form_data \\ %{}) do
    socket
    |> assign(:form, to_form(form_data))
    |> assign(:touched_fields, MapSet.new())
    |> assign(:validation_errors, %{})
    |> assign(:saving, false)
  end

  @doc """
  Debounces form input changes to reduce database writes.
  Cancels previous timers and sets a new one.
  """
  @spec debounce_change(Phoenix.LiveView.Socket.t(), atom() | String.t(), any(), integer()) ::
          Phoenix.LiveView.Socket.t()
  def debounce_change(socket, field, value, delay \\ 500) do
    timers = Map.get(socket.assigns, :debounce_timers, %{})
    pendings = Map.get(socket.assigns, :debounce_pending, %{})

    # Cancel existing timer for this field if present
    case Map.get(timers, field) do
      nil -> :ok
      timer_ref -> Process.cancel_timer(timer_ref)
    end

    # Store pending value and set new timer
    pendings = Map.put(pendings, field, value)
    timer_ref = Process.send_after(self(), {:execute_change, field, value}, delay)
    timers = Map.put(timers, field, timer_ref)

    socket
    |> assign(:debounce_pending, pendings)
    |> assign(:debounce_timers, timers)
  end

  @doc """
  Assigns form errors to socket with field-specific error mapping.
  """
  @spec assign_form_errors(Phoenix.LiveView.Socket.t(), list()) :: Phoenix.LiveView.Socket.t()
  def assign_form_errors(socket, errors) when is_list(errors) do
    error_map = Enum.group_by(errors, &elem(&1, 0), &elem(&1, 1))

    assign(socket, :validation_errors, error_map)
  end

  @spec assign_form_errors(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def assign_form_errors(socket, error_map) when is_map(error_map) do
    assign(socket, :validation_errors, error_map)
  end

  @doc """
  Handle form submission with loading state management.
  """
  @spec with_loading(
          Phoenix.LiveView.Socket.t(),
          (-> {:ok, any()} | {:error, any()})
        ) ::
          {:ok, Phoenix.LiveView.Socket.t(), any()} | {:error, Phoenix.LiveView.Socket.t(), any()}
  def with_loading(socket, fun) do
    socket = assign(socket, :saving, true)

    case fun.() do
      {:ok, result} ->
        {:ok, assign(socket, :saving, false), result}

      {:error, reason} ->
        {:error, assign(socket, :saving, false), reason}
    end
  end

  # ============================================================================
  # FORM FIELD COMPONENTS
  # ============================================================================

  @doc """
  Standard text input field with consistent styling and error handling.
  """
  attr :name, :string, required: true
  attr :value, :any, required: true
  attr :type, :string, default: "text"
  attr :label, :string, required: true
  attr :placeholder, :string, default: ""
  attr :help, :string, default: nil
  attr :debounce, :string, default: nil
  attr :errors, :list, default: []
  attr :required, :boolean, default: false
  attr :disabled, :boolean, default: false
  attr :class, :string, default: ""
  attr :rest, :global

  @spec text_field(map()) :: Phoenix.LiveView.Rendered.t()
  def text_field(assigns) do
    ~H"""
    <div class={@class}>
      <label for={@name} class="block text-sm font-medium text-gray-700 mb-2">
        {@label}
        <%= if @required do %>
          <span class="text-red-500 ml-1">*</span>
        <% end %>
      </label>
      <input
        type={@type}
        id={@name}
        name={@name}
        value={@value}
        placeholder={@placeholder}
        disabled={@disabled}
        phx-debounce={@debounce}
        class={[
          "w-full px-4 py-3 glass-input rounded-lg",
          "text-gray-800 placeholder-gray-500 transition-all duration-200",
          "focus:outline-none focus:ring-2 focus:ring-teal-500 focus:border-transparent",
          if(@disabled, do: "bg-gray-100 cursor-not-allowed", else: ""),
          if(@errors == [], do: "border-gray-300", else: "border-red-400")
        ]}
        {@rest}
      />
      <%= if @help do %>
        <p class="mt-2 text-sm text-gray-600">{@help}</p>
      <% end %>
      <.field_errors errors={@errors} />
    </div>
    """
  end

  @doc """
  Number input field with min/max validation and unit display.
  """
  attr :name, :string, required: true
  attr :value, :any, required: true
  attr :label, :string, required: true
  attr :min, :integer, required: true
  attr :max, :integer, required: true
  attr :step, :integer, default: 1
  attr :unit, :string, required: true
  attr :help, :string, default: nil
  attr :errors, :list, default: []
  attr :required, :boolean, default: false
  attr :disabled, :boolean, default: false
  attr :class, :string, default: ""

  @spec number_field(map()) :: Phoenix.LiveView.Rendered.t()
  def number_field(assigns) do
    ~H"""
    <div class={@class}>
      <label for={@name} class="block text-sm font-medium text-gray-700 mb-2">
        {@label}
        <%= if @required do %>
          <span class="text-red-500 ml-1">*</span>
        <% end %>
      </label>
      <div class="flex items-center space-x-3">
        <input
          type="number"
          id={@name}
          name={@name}
          value={@value}
          min={@min}
          max={@max}
          step={@step}
          disabled={@disabled}
          class={[
            "w-24 px-4 py-3 glass-input rounded-lg",
            "text-gray-800 placeholder-gray-500 transition-all duration-200",
            "focus:outline-none focus:ring-2 focus:ring-teal-500 focus:border-transparent",
            if(@disabled, do: "bg-gray-100 cursor-not-allowed", else: ""),
            if(@errors == [], do: "border-gray-300", else: "border-red-400")
          ]}
        />
        <span class="text-sm text-gray-600">{@unit}</span>
      </div>
      <%= if @help do %>
        <p class="mt-2 text-sm text-gray-600">{@help}</p>
      <% end %>
      <.field_errors errors={@errors} />
    </div>
    """
  end

  @doc """
  Select dropdown field with consistent styling.
  """
  attr :name, :string, required: true
  attr :value, :any, required: true
  attr :label, :string, required: true
  attr :options, :list, required: true
  attr :help, :string, default: nil
  attr :errors, :list, default: []
  attr :required, :boolean, default: false
  attr :disabled, :boolean, default: false
  attr :class, :string, default: ""
  attr :prompt, :string, default: nil

  @spec select_field(map()) :: Phoenix.LiveView.Rendered.t()
  def select_field(assigns) do
    ~H"""
    <div class={@class}>
      <label for={@name} class="block text-sm font-medium text-gray-700 mb-2">
        {@label}
        <%= if @required do %>
          <span class="text-red-500 ml-1">*</span>
        <% end %>
      </label>
      <div class="relative">
        <select
          id={@name}
          name={@name}
          disabled={@disabled}
          class={[
            "w-full px-4 py-3 glass-input rounded-lg appearance-none",
            "text-gray-800 transition-all duration-200",
            "focus:outline-none focus:ring-2 focus:ring-teal-500 focus:border-transparent",
            if(@disabled, do: "bg-gray-100 cursor-not-allowed", else: ""),
            if(@errors == [], do: "border-gray-300", else: "border-red-400")
          ]}
        >
          <%= if @prompt do %>
            <option value="">{@prompt}</option>
          <% end %>
          <%= for {label, option_value} <- @options do %>
            <option value={option_value} selected={option_value == @value}>
              {label}
            </option>
          <% end %>
        </select>
        <div class="absolute inset-y-0 right-0 flex items-center pr-3 pointer-events-none">
          <svg class="h-5 w-5 text-gray-600" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7" />
          </svg>
        </div>
      </div>
      <%= if @help do %>
        <p class="mt-2 text-sm text-gray-600">{@help}</p>
      <% end %>
      <.field_errors errors={@errors} />
    </div>
    """
  end

  @doc """
  Textarea field for longer text input.
  """
  attr :name, :string, required: true
  attr :value, :any, required: true
  attr :label, :string, required: true
  attr :placeholder, :string, default: ""
  attr :help, :string, default: nil
  attr :rows, :integer, default: 4
  attr :errors, :list, default: []
  attr :required, :boolean, default: false
  attr :disabled, :boolean, default: false
  attr :class, :string, default: ""
  attr :debounce, :string, default: nil
  attr :rest, :global

  @spec textarea_field(map()) :: Phoenix.LiveView.Rendered.t()
  def textarea_field(assigns) do
    ~H"""
    <div class={@class}>
      <label for={@name} class="block text-sm font-medium text-gray-700 mb-2">
        {@label}
        <%= if @required do %>
          <span class="text-red-500 ml-1">*</span>
        <% end %>
      </label>
      <textarea
        id={@name}
        name={@name}
        placeholder={@placeholder}
        rows={@rows}
        disabled={@disabled}
        phx-debounce={@debounce}
        class={[
          "w-full px-4 py-3 glass-input rounded-lg resize-none",
          "text-gray-800 placeholder-gray-500 transition-all duration-200",
          "focus:outline-none focus:ring-2 focus:ring-teal-500 focus:border-transparent",
          if(@disabled, do: "bg-gray-100 cursor-not-allowed", else: ""),
          if(@errors == [], do: "border-gray-300", else: "border-red-400")
        ]}
        {@rest}
      >{@value}</textarea>
      <%= if @help do %>
        <p class="mt-2 text-sm text-gray-600">{@help}</p>
      <% end %>
      <.field_errors errors={@errors} />
    </div>
    """
  end

  @doc """
  Checkbox field with label and help text.
  """
  attr :name, :string, required: true
  attr :checked, :boolean, required: true
  attr :label, :string, required: true
  attr :help, :string, default: nil
  attr :errors, :list, default: []
  attr :disabled, :boolean, default: false
  attr :class, :string, default: ""

  @spec checkbox_field(map()) :: Phoenix.LiveView.Rendered.t()
  def checkbox_field(assigns) do
    ~H"""
    <div class={@class}>
      <div class="flex items-start">
        <div class="flex items-center h-5">
          <input
            type="checkbox"
            id={@name}
            name={@name}
            checked={@checked}
            disabled={@disabled}
            class={[
              "h-4 w-4 text-teal-600 rounded transition-all duration-200",
              "focus:ring-teal-500 border-gray-300",
              if(@disabled, do: "cursor-not-allowed", else: "cursor-pointer")
            ]}
          />
        </div>
        <div class="ml-3 text-sm">
          <label
            for={@name}
            class={[
              "font-medium text-gray-700",
              if(@disabled, do: "cursor-not-allowed", else: "cursor-pointer")
            ]}
          >
            {@label}
          </label>
          <%= if @help do %>
            <p class="text-gray-600 mt-1">{@help}</p>
          <% end %>
        </div>
      </div>
      <.field_errors errors={@errors} />
    </div>
    """
  end

  # ============================================================================
  # FORM LAYOUT COMPONENTS
  # ============================================================================

  @doc """
  Form wrapper with consistent styling and submission handling.
  """
  attr :for, :any, required: true
  attr :phx_change, :string, default: nil
  attr :phx_submit, :string, default: nil
  attr :phx_target, :any, default: nil
  attr :class, :string, default: ""
  slot :inner_block, required: true

  @spec form_wrapper(map()) :: Phoenix.LiveView.Rendered.t()
  def form_wrapper(assigns) do
    ~H"""
    <.form
      for={@for}
      phx-change={@phx_change}
      phx-submit={@phx_submit}
      phx-target={@phx_target}
      class={["space-y-6", @class]}
    >
      {render_slot(@inner_block, @for)}
    </.form>
    """
  end

  @doc """
  Form section with title and description.
  """
  attr :title, :string, required: true
  attr :description, :string, default: nil
  attr :class, :string, default: ""
  slot :inner_block, required: true

  @spec form_section(map()) :: Phoenix.LiveView.Rendered.t()
  def form_section(assigns) do
    ~H"""
    <div class={["border-b border-gray-200 pb-6", @class]}>
      <div class="mb-4">
        <h3 class="text-lg font-medium text-gray-900">{@title}</h3>
        <%= if @description do %>
          <p class="mt-1 text-sm text-gray-600">{@description}</p>
        <% end %>
      </div>
      {render_slot(@inner_block)}
    </div>
    """
  end

  @doc """
  Form action buttons with consistent styling.
  """
  attr :saving, :boolean, default: false
  attr :cancel_text, :string, default: "Cancel"
  attr :submit_text, :string, default: "Save"
  attr :cancel_event, :string, default: nil
  attr :phx_target, :any, default: nil
  attr :class, :string, default: ""

  @spec form_actions(map()) :: Phoenix.LiveView.Rendered.t()
  def form_actions(assigns) do
    ~H"""
    <div class={["flex justify-end space-x-3 pt-4", @class]}>
      <%= if @cancel_event do %>
        <button
          type="button"
          phx-click={@cancel_event}
          phx-target={@phx_target}
          disabled={@saving}
          class="px-4 py-2 text-sm font-medium text-gray-700 bg-white rounded-lg border border-gray-300 hover:bg-gray-50 focus:outline-none focus:ring-2 focus:ring-teal-500 disabled:opacity-50 disabled:cursor-not-allowed transition-all duration-200"
        >
          {@cancel_text}
        </button>
      <% end %>
      <button
        type="submit"
        disabled={@saving}
        class="px-4 py-2 text-sm font-medium text-white bg-teal-600 rounded-lg hover:bg-teal-700 focus:outline-none focus:ring-2 focus:ring-teal-500 disabled:opacity-50 disabled:cursor-not-allowed transition-all duration-200"
      >
        <%= if @saving do %>
          <div class="flex items-center">
            <svg class="animate-spin -ml-1 mr-2 h-4 w-4 text-white" fill="none" viewBox="0 0 24 24">
              <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4">
              </circle>
              <path
                class="opacity-75"
                fill="currentColor"
                d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
              >
              </path>
            </svg>
            Saving...
          </div>
        <% else %>
          {@submit_text}
        <% end %>
      </button>
    </div>
    """
  end

  # ============================================================================
  # VALIDATION UTILITIES
  # ============================================================================

  @doc """
  Validate numeric input within range.
  """
  @spec validate_number(String.t() | integer(), integer(), integer()) ::
          {:ok, integer()} | {:error, String.t()}
  def validate_number(value, min, max) when is_binary(value) do
    case Integer.parse(value) do
      {num, ""} when num >= min and num <= max -> {:ok, num}
      _ -> {:error, "Please enter a valid number between #{min} and #{max}"}
    end
  end

  def validate_number(value, min, max) when is_integer(value) do
    if value >= min and value <= max do
      {:ok, value}
    else
      {:error, "Please enter a valid number between #{min} and #{max}"}
    end
  end

  @doc """
  Validate required field is not empty.
  """
  @spec validate_required(any()) :: {:ok, any()} | {:error, String.t()}
  def validate_required(value) when is_binary(value) do
    if String.trim(value) != "" do
      {:ok, String.trim(value)}
    else
      {:error, "This field is required"}
    end
  end

  def validate_required(nil), do: {:error, "This field is required"}
  def validate_required(""), do: {:error, "This field is required"}
  def validate_required(value), do: {:ok, value}

  @doc """
  Validate email format.
  """
  @spec validate_email(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def validate_email(email) when is_binary(email) do
    email = String.trim(email)

    if String.match?(email, ~r/^[^\s]+@[^\s]+\.[^\s]+$/) do
      {:ok, email}
    else
      {:error, "Please enter a valid email address"}
    end
  end

  # ============================================================================
  # PRIVATE COMPONENTS
  # ============================================================================

  defp field_errors(assigns) do
    ~H"""
    <%= if @errors != [] do %>
      <div class="mt-1">
        <%= for error <- @errors do %>
          <p class="text-sm text-red-600">{error}</p>
        <% end %>
      </div>
    <% end %>
    """
  end
end
