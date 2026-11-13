defmodule TymeslotWeb.OAuthController.InvitationResponse do
  @moduledoc """
  How `TymeslotWeb.OAuthController` answers a provider sign-in started from an
  invitation page: a welcome on success, and otherwise a flash and a way back,
  to the invitation while it is still pending or to the login page once it is
  spent or the account is ready.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  use Phoenix.VerifiedRoutes,
    endpoint: TymeslotWeb.Endpoint,
    router: TymeslotWeb.Router,
    statics: TymeslotWeb.static_paths()

  import Phoenix.Controller, only: [put_flash: 3, redirect: 2]

  alias Tymeslot.Auth.OAuth.Providers
  alias Tymeslot.Infrastructure.Config
  alias TymeslotWeb.InvitationHTML

  @doc "Answers the outcome of an invitation accepted through a provider sign-in."
  @spec respond(tuple(), String.t()) :: Plug.Conn.t()
  def respond({:ok, authed_conn, provider}, _token) do
    authed_conn
    |> put_flash(
      :success,
      dgettext("auth_oauth", "Welcome to Tymeslot! You'll sign in with %{provider}.",
        provider: Providers.name(provider)
      )
    )
    |> redirect(to: Config.success_redirect_path())
  end

  def respond({:error, :invalid_state, conn}, token) do
    conn
    |> put_flash(:error, dgettext("auth_oauth", "Security validation failed. Please try again."))
    |> redirect(to: ~p"/auth/invitation/#{token}")
  end

  # The account is ready but has no session: the identity is linked, so the
  # ordinary social sign-in reaches it.
  def respond({:error, :session_failed, provider, conn}, _token) do
    conn
    |> put_flash(
      :info,
      dgettext(
        "auth_oauth",
        "Your account is ready. Please sign in with %{provider} to continue.",
        provider: Providers.name(provider)
      )
    )
    |> redirect(to: ~p"/auth/login")
  end

  def respond({:error, reason, _provider, conn}, _token)
      when reason in [:invalid_token, :token_expired] do
    conn
    |> put_flash(:error, InvitationHTML.refusal_message(reason))
    |> redirect(to: ~p"/auth/login")
  end

  # The invitation is still pending: back to its page to choose again.
  def respond({:error, reason, provider, conn}, token) do
    conn
    |> put_flash(:error, invitation_failure_message(reason, provider))
    |> redirect(to: ~p"/auth/invitation/#{token}")
  end

  defp invitation_failure_message(:identity_in_use, provider),
    do:
      dgettext(
        "auth_oauth",
        "This %{provider} account already signs in to another Tymeslot account. Use a different one, or choose another way to sign in.",
        provider: Providers.name(provider)
      )

  defp invitation_failure_message(:provider_disabled, provider),
    do:
      dgettext("auth_oauth", "%{provider} authentication is not available",
        provider: Providers.name(provider)
      )

  defp invitation_failure_message(:rate_limited, _provider),
    do: dgettext("auth_invitation", "Too many OAuth attempts. Please try again later.")

  defp invitation_failure_message(:oauth_error, provider),
    do:
      dgettext("auth_oauth", "Failed to authenticate with %{provider}.",
        provider: Providers.name(provider)
      )

  defp invitation_failure_message(_general_error, provider),
    do:
      dgettext("auth_oauth", "An error occurred during %{provider} authentication.",
        provider: Providers.name(provider)
      )
end
