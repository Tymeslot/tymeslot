defmodule TymeslotWeb.AccountLive.Forms do
  @moduledoc """
  Form components for email and password management.
  Provides reusable form fields and submission buttons.
  """
  use Phoenix.Component
  import TymeslotWeb.Components.CoreComponents

  @doc """
  Renders the email change form.
  """
  attr :errors, :map, required: true
  attr :saving, :boolean, required: true

  @spec email_form(map()) :: Phoenix.LiveView.Rendered.t()
  def email_form(assigns) do
    ~H"""
    <form phx-submit="update_email" class="space-y-4">
      <.input
        name="email_form[new_email]"
        type="email"
        label="New Email Address"
        placeholder="your.new@email.com"
        errors={Map.get(@errors, :new_email) || []}
        required
        icon="hero-envelope"
      />

      <.input
        name="email_form[current_password]"
        type="password"
        label="Current Password"
        placeholder="Enter your current password"
        errors={Map.get(@errors, :current_password) || []}
        required
        icon="hero-lock-closed"
      />

      <.form_errors errors={Map.get(@errors, :base)} />
      <.submit_button text="Update Email" saving={@saving} />
    </form>
    """
  end

  @doc """
  Renders the password change form.
  """
  attr :errors, :map, required: true
  attr :saving, :boolean, required: true

  @spec password_form(map()) :: Phoenix.LiveView.Rendered.t()
  def password_form(assigns) do
    ~H"""
    <form phx-submit="update_password" class="space-y-4">
      <.input
        name="password_form[current_password]"
        type="password"
        label="Current Password"
        placeholder="Enter your current password"
        errors={Map.get(@errors, :current_password) || []}
        required
        icon="hero-lock-closed"
      />

      <.input
        name="password_form[new_password]"
        type="password"
        label="New Password"
        placeholder="At least 8 characters"
        errors={Map.get(@errors, :new_password) || []}
        minlength={8}
        required
        icon="hero-lock-closed"
      />

      <.input
        name="password_form[new_password_confirmation]"
        type="password"
        label="Confirm New Password"
        placeholder="Confirm your new password"
        errors={Map.get(@errors, :new_password_confirmation) || []}
        minlength={8}
        required
        icon="hero-lock-closed"
      />

      <.form_errors errors={Map.get(@errors, :base)} />
      <.submit_button text="Update Password" saving={@saving} />
    </form>
    """
  end

  @doc """
  Renders form-level error messages.
  """
  attr :errors, :any, default: nil

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
  attr :text, :string, required: true
  attr :saving, :boolean, required: true

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
end
