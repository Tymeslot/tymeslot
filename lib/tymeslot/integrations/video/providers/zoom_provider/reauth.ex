defmodule Tymeslot.Integrations.Video.Providers.ZoomProvider.Reauth do
  @moduledoc """
  Decides when a Zoom integration needs reconnecting, and records it.

  Two things put a Zoom integration beyond use until the account owner
  re-consents: a grant revoked at zoom.us, and a grant whose scopes do not
  cover the operation being attempted. Both end in the same "Reconnect
  required" badge, and both must be told apart from an ordinary transient
  failure so the caller discards rather than retrying.

  There is a third case that looks identical from the API's point of view and
  must not be treated the same. When Tymeslot never asks Zoom for the scope in
  question, no user's grant can hold it, so the shortfall belongs to the
  Marketplace app rather than to any account owner. Asking them to reconnect
  would send them round a loop that cannot end, so that case is logged for the
  operator and kept off the dashboard entirely. `Scopes.requestable?/1` is the
  line between the two.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Integrations.Video.OAuthTokenManager
  alias Tymeslot.Integrations.Video.Providers.ZoomProvider.Scopes

  require Logger

  @type config :: %{optional(atom()) => term()}

  @doc """
  Checks the integration's stored grant against what `operation` needs.

  Flags the integration and returns `{:error, :insufficient_scope}` when the
  grant falls short, so callers can discard rather than replay a request Zoom
  is certain to refuse.
  """
  @spec validate_scope(config(), Scopes.operation()) ::
          {:ok, :valid} | {:error, :insufficient_scope}
  def validate_scope(config, operation) do
    stored_scope = String.downcase(Map.get(config, :oauth_scope) || "")

    if Scopes.satisfied?(stored_scope, operation) do
      {:ok, :valid}
    else
      Logger.error("Zoom integration missing required scope",
        stored_scope: stored_scope,
        operation: operation,
        required_scope: Scopes.required_description(operation)
      )

      flag_missing_scope(config, operation)
      {:error, :insufficient_scope}
    end
  end

  @doc """
  Flags a grant that cannot authorise `operation`.

  A grant predating a scope change can only be widened by re-consenting, so it
  needs the same badge as a revoked token — but only when re-consenting would
  actually produce the scope. See the moduledoc for the case where it would
  not.
  """
  @spec flag_missing_scope(config(), Scopes.operation()) :: :ok
  def flag_missing_scope(config, operation) do
    if Scopes.requestable?(operation) do
      flag_for_reauth(config, "zoom_missing_scope", Scopes.reauth_message(operation))
    else
      Logger.error(
        "Zoom app does not request a scope Tymeslot needs; reconnecting cannot fix this",
        operation: operation,
        required_scope: Scopes.required_description(operation)
      )

      :ok
    end
  end

  @doc """
  Flags a grant revoked at zoom.us.

  Called after a 401 that survived a forced token refresh, which is the point
  at which server-side revocation is the only remaining explanation.
  """
  @spec flag_revoked_token(config()) :: :ok
  def flag_revoked_token(config) do
    flag_for_reauth(
      config,
      "zoom_token_revoked",
      dgettext(
        "dashboard_integrations",
        "Zoom access was revoked. Please reconnect your Zoom account."
      )
    )
  end

  defp flag_for_reauth(config, event, message) do
    OAuthTokenManager.flag_needs_reauth(config, label: "Zoom", event: event, message: message)
  end
end
