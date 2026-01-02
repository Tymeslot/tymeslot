defmodule TymeslotWeb.Registration.CompleteRegistrationComponent do
  @moduledoc """
  OAuth registration completion component.

  Provides the UI for users to complete their registration
  after OAuth authentication when additional information is required.
  """

  use TymeslotWeb, :html
  import TymeslotWeb.Shared.Auth.LayoutComponents
  import TymeslotWeb.Shared.Auth.FormComponents
  import TymeslotWeb.Shared.Auth.InputComponents
  import TymeslotWeb.Shared.Auth.ButtonComponents
  import TymeslotWeb.Shared.Auth.IconComponents

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
          action="/auth/complete"
        >
          <!-- Hidden OAuth fields -->
          <.oauth_hidden_fields temp_user={@temp_user} />

          <.full_name_input />
          <.email_input email_required={@email_required} temp_user={@temp_user} />
          <%= if Tymeslot.Deployment.main?() do %>
            <.terms_checkbox name="auth[terms_accepted]" style={:complex} />
          <% end %>
          <.auth_button type="submit" class="mt-4 sm:mt-6">
            Complete Registration
          </.auth_button>
        </.auth_form>
      </:form>
      <:footer>
        <.auth_footer prompt="Want to start over?" href="/auth/login" link_text="Return to login" />
      </:footer>
    </.auth_card_layout>
    """
  end

  # Private function components
  defp full_name_input(assigns) do
    ~H"""
    <div class="grid grid-cols-1 sm:grid-cols-2 gap-3 sm:gap-4">
      <div>
        <.form_label for="full-name" text="Full Name" />
        <.auth_text_input
          id="full-name"
          name="profile[full_name]"
          type="text"
          placeholder="Full name"
          required={true}
        />
      </div>
    </div>
    """
  end

  defp email_input(assigns) do
    ~H"""
    <%= if @email_required do %>
      <div>
        <.form_label for="email" text="Email Address" />
        <.auth_text_input
          id="email"
          name="auth[email]"
          type="email"
          placeholder="your.email@example.com"
          required={true}
          class="border-primary-100/50"
        >
          <div class="absolute inset-y-0 right-0 pr-3 flex items-center pointer-events-none">
            <.email_icon />
          </div>
        </.auth_text_input>
      </div>
    <% else %>
      <input type="hidden" name="auth[email]" value={@temp_user.email} />
    <% end %>
    """
  end

  defp oauth_hidden_fields(assigns) do
    ~H"""
    <div>
      <input type="hidden" name="oauth_provider" value={@temp_user.provider} />
      <input type="hidden" name="oauth_verified" value={to_string(@temp_user.verified_email)} />
      <input type="hidden" name="oauth_email" value={@temp_user.email} />
      <input type="hidden" name="oauth_email_from_provider" value="true" />
      <%= if @temp_user[:name] do %>
        <input type="hidden" name="oauth_name" value={@temp_user.name} />
      <% end %>
      <%= if @temp_user.github_user_id do %>
        <input type="hidden" name="oauth_github_id" value={@temp_user.github_user_id} />
      <% end %>
      <%= if @temp_user.google_user_id do %>
        <input type="hidden" name="oauth_google_id" value={@temp_user.google_user_id} />
      <% end %>
    </div>
    """
  end
end
