defmodule TymeslotWeb.AccountLive.Forms do
  @moduledoc """
  Form components for email and password management.
  Provides reusable form fields and submission buttons.
  """
  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext
  alias Tymeslot.Validation.Constraints
  import TymeslotWeb.Components.CoreComponents

  @doc """
  Renders the email change form.
  """
  attr :errors, :map, required: true
  attr :saving, :boolean, required: true

  @spec email_form(map()) :: Phoenix.LiveView.Rendered.t()
  def email_form(assigns) do
    ~H"""
    <form id="account-email-form" phx-submit="update_email" class="space-y-4">
      <.input
        name="email_form[new_email]"
        type="email"
        label={dgettext("account", "New Email Address")}
        placeholder={dgettext("account", "your.new@email.com")}
        errors={Map.get(@errors, :new_email) || []}
        required
        icon="hero-envelope"
      />

      <.input
        name="email_form[current_password]"
        type="password"
        label={dgettext("account", "Current Password")}
        placeholder={dgettext("account", "Enter your current password")}
        errors={Map.get(@errors, :current_password) || []}
        required
        icon="hero-lock-closed"
      />

      <.form_errors errors={Map.get(@errors, :base)} />
      <.submit_button
        text={dgettext("account", "Update Email")}
        loading_text={dgettext("account", "Updating Email")}
        saving={@saving}
      />
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
    <form id="account-password-form" phx-submit="update_password" class="space-y-4">
      <.input
        name="password_form[current_password]"
        type="password"
        label={dgettext("account", "Current Password")}
        placeholder={dgettext("account", "Enter your current password")}
        errors={Map.get(@errors, :current_password) || []}
        required
        icon="hero-lock-closed"
      />

      <.input
        name="password_form[new_password]"
        type="password"
        label={dgettext("account", "New Password")}
        placeholder={dgettext("account", "At least 8 characters")}
        errors={Map.get(@errors, :new_password) || []}
        minlength={Constraints.password_length_range().first}
        required
        icon="hero-lock-closed"
      />

      <.input
        name="password_form[new_password_confirmation]"
        type="password"
        label={dgettext("account", "Confirm New Password")}
        placeholder={dgettext("account", "Confirm your new password")}
        errors={Map.get(@errors, :new_password_confirmation) || []}
        minlength={Constraints.password_length_range().first}
        required
        icon="hero-lock-closed"
      />

      <.form_errors errors={Map.get(@errors, :base)} />
      <.submit_button
        text={dgettext("account", "Update Password")}
        loading_text={dgettext("account", "Updating Password")}
        saving={@saving}
      />
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
  attr :loading_text, :string, required: true

  @spec submit_button(map()) :: Phoenix.LiveView.Rendered.t()
  def submit_button(assigns) do
    ~H"""
    <div class="flex justify-end">
      <button type="submit" disabled={@saving} class="btn btn-primary">
        <%= if @saving do %>
          <span class="flex items-center">
            <.spinner />
            {@loading_text}...
          </span>
        <% else %>
          {@text}
        <% end %>
      </button>
    </div>
    """
  end
end
