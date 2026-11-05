defmodule TymeslotWeb.InvitationHTML do
  @moduledoc """
  The invitation acceptance page: the invited address and the form that sets
  its first password.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  attr :action, :string, required: true, doc: "The URL the form is POSTed to"
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
            {dgettext("auth", "Accept your invitation")}
          </h1>
          <p class="mt-2 text-token-base text-tymeslot-600">
            {dgettext("auth", "Choose a password for %{email} to finish setting up your account.",
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

        <form method="post" action={@action} class="mt-6 space-y-4" id="accept-invitation-form">
          <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
          <input type="hidden" name="username" value={@email} autocomplete="username" />

          <.input
            id="invitation_password"
            name="invitation[password]"
            type="password"
            value=""
            label={dgettext("auth", "Password")}
            autocomplete="new-password"
            required
          />
          <.password_requirements />

          <.input
            id="invitation_password_confirmation"
            name="invitation[password_confirmation]"
            type="password"
            value=""
            label={dgettext("auth", "Confirm password")}
            autocomplete="new-password"
            required
          />

          <.action_button type="submit" class="w-full">
            {dgettext("auth", "Set password and sign in")}
          </.action_button>
        </form>
      </div>
    </main>
    """
  end
end
