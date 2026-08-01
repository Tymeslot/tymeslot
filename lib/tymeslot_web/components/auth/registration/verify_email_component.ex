defmodule TymeslotWeb.Registration.VerifyEmailComponent do
  @moduledoc """
  Email verification component.

  Provides the UI for email verification prompts and
  resend functionality during the registration process.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext
  import TymeslotWeb.Shared.Auth.LayoutComponents

  @doc """
  Renders the verify email page using shared auth components.
  """
  @spec verify_email_page(map()) :: Phoenix.LiveView.Rendered.t()
  def verify_email_page(assigns) do
    ~H"""
    <.auth_card_layout title={dgettext("auth", "Verify Your Email")}>
      <:heading>
        <h2 class="text-xl font-bold text-tymeslot-900 mb-6 tracking-tight text-center">
          {dgettext("auth", "Almost There!")}
        </h2>
      </:heading>

      <:form>
        <.email_verification_message email={
          get_in(assigns, [:form_data, :email]) || get_in(assigns, [:unverified_user, :email])
        } />
        <div class="mt-6 sm:mt-8 space-y-4">
          <.resend_verification_button
            loading={assigns[:loading] || false}
            cooldown={assigns[:resend_cooldown] || 0}
          />
          <div class="relative py-2">
            <div class="absolute inset-0 flex items-center" aria-hidden="true">
              <div class="w-full border-t border-tymeslot-100"></div>
            </div>
            <div class="relative flex justify-center text-token-2xs font-black uppercase tracking-[0.2em]">
              <span class="bg-transparent px-4 text-tymeslot-400">{dgettext("auth", "or")}</span>
            </div>
          </div>
          <button
            type="button"
            phx-click="navigate_to"
            phx-value-state="login"
            class="btn-secondary w-full py-3.5 text-base"
          >
            {dgettext("auth", "Back to Login")}
          </button>
        </div>
      </:form>
    </.auth_card_layout>
    """
  end

  attr :email, :string, default: nil

  defp email_verification_message(assigns) do
    ~H"""
    <div class="text-center mb-8">
      <p class="text-base text-tymeslot-600 font-medium max-w-md mx-auto leading-relaxed">
        {dgettext(
          "auth",
          "We've just sent you a verification email! Please click the link in the email to confirm your address and finish setting up your account."
        )}
      </p>
      <%= if @email do %>
        <div class="mt-6 p-4 bg-tymeslot-50/50 border-2 border-tymeslot-100/50 rounded-2xl inline-block">
          <p class="text-token-2xs font-black text-tymeslot-400 uppercase tracking-widest mb-1">
            {dgettext("auth", "Sent to")}
          </p>
          <p class="text-tymeslot-900 font-bold text-base">{@email}</p>
        </div>
      <% end %>
    </div>
    """
  end

  defp resend_verification_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="resend_verification"
      disabled={@loading or @cooldown > 0}
      class="btn-primary w-full py-3.5 text-base"
    >
      <%= cond do %>
        <% @loading -> %>
          <.spinner class="-ml-1 mr-3 h-5 w-5 text-white inline-block" />
          {dgettext("auth", "Sending...")}
        <% @cooldown > 0 -> %>
          {dngettext(
            "auth",
            "Resend available in %{count}s",
            "Resend available in %{count}s",
            @cooldown
          )}
        <% true -> %>
          <.icon name="hero-arrow-path" class="w-5 h-5 mr-2 inline-block" />
          {dgettext("auth", "Resend Verification Email")}
      <% end %>
    </button>
    """
  end
end
