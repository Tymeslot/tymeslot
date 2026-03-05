defmodule TymeslotWeb.Registration.CompleteRegistrationComponent do
  @moduledoc """
  OAuth registration completion component.

  Provides the UI for users to complete their registration
  after OAuth authentication when additional information is required.
  """

  use TymeslotWeb, :html
  import TymeslotWeb.Shared.Auth.LayoutComponents
  import TymeslotWeb.Shared.Auth.FormComponents
  import TymeslotWeb.Shared.Auth.ButtonComponents
  import TymeslotWeb.Components.CoreComponents

  @doc """
  Renders the complete registration form using shared auth components.
  """
  @spec complete_registration_form(map()) :: Phoenix.LiveView.Rendered.t()
  def complete_registration_form(assigns) do
    ~H"""
    <.auth_card_layout
      title="Complete Your Registration"
      subtitle="Thank you for signing up! Let's finish setting up your account."
    >
      <:form>
        <.auth_form
          id="complete-registration-form"
          class="space-y-3 sm:space-y-4"
          action={~p"/auth/complete"}
        >
          <.full_name_input />
          <.email_input email_required={@email_required} temp_user={@temp_user} />
          <%= if Application.get_env(:tymeslot, :enforce_legal_agreements, false) do %>
            <.terms_checkbox name="auth[terms_accepted]" style={:complex} />
          <% end %>
          <.auth_button type="submit" class="mt-4 sm:mt-6">
            Complete Registration
          </.auth_button>
        </.auth_form>
      </:form>
      <:footer>
        <.auth_footer prompt="Want to start over?" href={~p"/auth/login"} link_text="Return to login" />
      </:footer>
    </.auth_card_layout>
    """
  end

  # Private function components
  defp full_name_input(assigns) do
    ~H"""
    <.input
      id="full-name"
      name="profile[full_name]"
      type="text"
      label="Display Name"
      placeholder="e.g. John Doe"
      required
      icon="hero-user"
    />
    """
  end

  defp email_input(assigns) do
    ~H"""
    <%= if @email_required do %>
      <.input
        id="email"
        name="auth[email]"
        type="email"
        label="Email Address"
        placeholder="your.email@example.com"
        required
        icon="hero-envelope"
      />
    <% else %>
      <input type="hidden" name="auth[email]" value={@temp_user.email} />
    <% end %>
    """
  end
end
