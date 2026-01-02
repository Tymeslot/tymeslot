defmodule TymeslotWeb.AccountLive.Forms do
  @moduledoc """
  Form components for email and password management.
  Provides reusable form fields and submission buttons.
  """
  use Phoenix.Component

  @doc """
  Renders the email change form.
  """
  @spec email_form(map()) :: Phoenix.LiveView.Rendered.t()
  def email_form(assigns) do
    ~H"""
    <form phx-submit="update_email" class="space-y-4">
      <.form_field
        name="email_form[new_email]"
        type="email"
        label="New Email Address"
        placeholder="your.new@email.com"
        errors={Map.get(@errors, :new_email)}
        required={true}
      />

      <.form_field
        name="email_form[current_password]"
        type="password"
        label="Current Password"
        placeholder="Enter your current password"
        errors={Map.get(@errors, :current_password)}
        required={true}
      />

      <.form_errors errors={Map.get(@errors, :base)} />
      <.submit_button text="Update Email" saving={@saving} />
    </form>
    """
  end

  @doc """
  Renders the password change form.
  """
  @spec password_form(map()) :: Phoenix.LiveView.Rendered.t()
  def password_form(assigns) do
    ~H"""
    <form phx-submit="update_password" class="space-y-4">
      <.form_field
        name="password_form[current_password]"
        type="password"
        label="Current Password"
        placeholder="Enter your current password"
        errors={Map.get(@errors, :current_password)}
        required={true}
      />

      <.form_field
        name="password_form[new_password]"
        type="password"
        label="New Password"
        placeholder="At least 8 characters"
        errors={Map.get(@errors, :new_password)}
        minlength={8}
        required={true}
      />

      <.form_field
        name="password_form[new_password_confirmation]"
        type="password"
        label="Confirm New Password"
        placeholder="Confirm your new password"
        errors={Map.get(@errors, :new_password_confirmation)}
        minlength={8}
        required={true}
      />

      <.form_errors errors={Map.get(@errors, :base)} />
      <.submit_button text="Update Password" saving={@saving} />
    </form>
    """
  end

  @doc """
  Renders a form field with label, input, and error messages.
  """
  @spec form_field(map()) :: Phoenix.LiveView.Rendered.t()
  def form_field(assigns) do
    assigns =
      assigns
      |> assign_new(:errors, fn -> nil end)
      |> assign_new(:minlength, fn -> nil end)
      |> assign_new(:required, fn -> false end)
      |> assign_new(:phx_blur, fn -> nil end)

    ~H"""
    <div>
      <label for={input_id(@name)} class="label text-gray-700">
        {@label}
      </label>
      <input
        type={@type}
        id={input_id(@name)}
        name={@name}
        class={input_classes(@errors)}
        placeholder={@placeholder}
        required={@required}
        minlength={@minlength}
        phx-blur={@phx_blur}
      />
      <.field_errors errors={@errors} />
    </div>
    """
  end

  @doc """
  Renders field-level error messages.
  """
  @spec field_errors(map()) :: Phoenix.LiveView.Rendered.t()
  def field_errors(assigns) do
    ~H"""
    <%= if @errors do %>
      <p class="mt-1 text-sm text-red-400">{Enum.join(@errors, ", ")}</p>
    <% end %>
    """
  end

  @doc """
  Renders form-level error messages.
  """
  @spec form_errors(map()) :: Phoenix.LiveView.Rendered.t()
  def form_errors(assigns) do
    ~H"""
    <%= if @errors do %>
      <p class="text-sm text-red-400">{Enum.join(@errors, ", ")}</p>
    <% end %>
    """
  end

  @doc """
  Renders a submit button with loading state.
  """
  @spec submit_button(map()) :: Phoenix.LiveView.Rendered.t()
  def submit_button(assigns) do
    ~H"""
    <div class="flex justify-end">
      <button type="submit" disabled={@saving} class="btn btn-primary">
        <%= if @saving do %>
          <span class="flex items-center">
            <.spinner />
            {@text |> String.replace("Update", "Updating")}...
          </span>
        <% else %>
          {@text}
        <% end %>
      </button>
    </div>
    """
  end

  @doc """
  Renders a loading spinner.
  """
  @spec spinner(map()) :: Phoenix.LiveView.Rendered.t()
  def spinner(assigns) do
    ~H"""
    <svg class="animate-spin h-4 w-4 mr-2" fill="none" viewBox="0 0 24 24">
      <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4" />
      <path
        class="opacity-75"
        fill="currentColor"
        d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
      />
    </svg>
    """
  end

  # Private helper functions
  defp input_id(name) do
    # Safely convert field name to HTML ID
    # Handles edge cases where name might be nil or malformed
    case name do
      nil ->
        "field"

      name when is_binary(name) ->
        name
        |> String.replace(~r/\[|\]/, "_")
        |> String.trim("_")

      _ ->
        "field"
    end
  end

  defp input_classes(errors) do
    base = "glass-input"
    if errors, do: "#{base} input-error", else: base
  end
end
