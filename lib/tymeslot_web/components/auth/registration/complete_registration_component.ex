defmodule TymeslotWeb.Registration.CompleteRegistrationComponent do
  @moduledoc """
  OAuth registration completion component.

  Provides the UI for users to complete their registration
  after OAuth authentication when additional information is required.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext
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
      title={dgettext("auth", "Complete Your Registration")}
      subtitle={dgettext("auth", "Thank you for signing up! Let's finish setting up your account.")}
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
            {dgettext("auth", "Complete Registration")}
          </.auth_button>
        </.auth_form>
      </:form>
      <:footer>
        <.auth_footer
          prompt={dgettext("auth", "Want to start over?")}
          href={~p"/auth/login"}
          link_text={dgettext("auth", "Return to login")}
        />
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
      label={dgettext("auth", "Display Name")}
      placeholder={dgettext("auth", "e.g. John Doe")}
      required
      autofocus
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
        label={dgettext("auth", "Email Address")}
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
