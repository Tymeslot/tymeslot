defmodule TymeslotWeb.InvitationHTML do
  @moduledoc """
  The invitation acceptance page: the invited address, the form that sets
  its first password when password sign-in is on, and a button for each
  enabled social sign-in provider.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  import TymeslotWeb.Shared.SocialAuthButtons

  @doc """
  Why an invitation link can no longer be accepted, for the flash shown on
  the way back to the login page.
  """
  @spec refusal_message(atom()) :: String.t()
  def refusal_message(:token_expired),
    do:
      dgettext(
        "auth_invitation",
        "This invitation has expired. Ask your administrator to send you a new one."
      )

  def refusal_message(:password_auth_disabled),
    do:
      dgettext(
        "auth_invitation",
        "Password sign-in is turned off. Please choose another way to sign in."
      )

  def refusal_message(:no_sign_in_method),
    do:
      dgettext(
        "auth_invitation",
        "No sign-in method is switched on, so this invitation can't be accepted. Please contact your administrator."
      )

  def refusal_message(_invalid),
    do:
      dgettext(
        "auth_invitation",
        "This invitation link is no longer valid. It may have been used already, or replaced by a newer invitation."
      )

  attr :action, :string, required: true, doc: "The URL the password form is POSTed to"
  attr :social_path, :string, required: true, doc: "The prefix of each provider's start URL"
  attr :password_enabled, :boolean, required: true
  attr :email, :string, required: true
  attr :error, :string, default: nil

  @spec show(map()) :: Phoenix.LiveView.Rendered.t()
  def show(assigns) do
    ~H"""
    <main class="flex min-h-screen items-center justify-center bg-linear-to-br from-turquoise-50 via-white to-cyan-50 p-4">
      <div class="w-full max-w-md rounded-token-2xl bg-white p-8 shadow-glass-lg">
        <div class="text-center">
          <div class="mx-auto flex h-16 w-16 items-center justify-center rounded-token-full bg-turquoise-100 text-turquoise-600">
            <.icon name="hero-envelope-open" class="h-9 w-9" />
          </div>

          <h1 class="mt-6 text-token-2xl font-bold text-tymeslot-800">
            {dgettext("auth_invitation", "Accept your invitation")}
          </h1>
          <p class="mt-2 text-token-base text-tymeslot-600">
            {dgettext(
              "auth_invitation",
              "Choose how you'll sign in as %{email} to finish setting up your account.",
              email: @email
            )}
          </p>
        </div>

        <p
          :if={@error}
          class="mt-6 rounded-token-lg border-2 border-red-200 bg-red-50 p-4 text-token-sm font-medium text-red-800"
          role="alert"
        >
          {@error}
        </p>

        <form
          :if={@password_enabled}
          method="post"
          action={@action}
          class="mt-6 space-y-4"
          id="accept-invitation-form"
        >
          <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
          <input type="hidden" name="username" value={@email} autocomplete="username" />

          <.input
            id="invitation_password"
            name="invitation[password]"
            type="password"
            value=""
            label={dgettext("auth_invitation", "Password")}
            autocomplete="new-password"
            required
          />
          <.password_requirements />

          <.input
            id="invitation_password_confirmation"
            name="invitation[password_confirmation]"
            type="password"
            value=""
            label={dgettext("auth_invitation", "Confirm password")}
            autocomplete="new-password"
            required
          />

          <.action_button type="submit" class="w-full">
            {dgettext("auth_invitation", "Set password and sign in")}
          </.action_button>
        </form>

        <div class="mt-6 space-y-4" data-testid="invitation-social-sign-in">
          <p :if={@password_enabled} class="text-center text-token-sm text-tymeslot-500">
            {dgettext("auth_invitation", "Or sign in with")}
          </p>
          <.social_auth_buttons post_prefix={@social_path} />
        </div>
      </div>
    </main>
    """
  end
end
