defmodule Tymeslot.Integrations.Calendar.OAuth do
  @moduledoc """
  OAuth helper functions for calendar providers (Google, Outlook).
  """

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Google.OAuthHelper, as: GoogleOAuthHelper
  alias Tymeslot.Integrations.Calendar.Google.Provider, as: GoogleProvider
  alias Tymeslot.Integrations.Calendar.Management
  alias Tymeslot.Integrations.Calendar.Outlook.OAuthHelper, as: OutlookOAuthHelper
  alias Tymeslot.Integrations.Shared.OAuth.PendingFlow
  alias Tymeslot.Integrations.Shared.OAuth.State
  alias Tymeslot.Integrations.Shared.OAuthConfig
  alias TymeslotWeb.Endpoint

  @type user_id :: pos_integer()

  @typedoc "A calendar provider that authenticates over OAuth."
  @type provider :: :google | :outlook

  # `label` names the provider in operator-facing errors; `config` is the
  # OAuth client whose credentials and state secret its flow uses; `url_helper`
  # is the application key that can swap the helper building authorisation
  # URLs for a test double. The callback exchange goes to `helper` directly:
  # those doubles implement only the URL half of the flow.
  @providers %{
    google: %{
      label: "Google",
      config: :google,
      helper: GoogleOAuthHelper,
      url_helper: :google_calendar_oauth_helper
    },
    outlook: %{
      label: "Outlook",
      config: :microsoft,
      helper: OutlookOAuthHelper,
      url_helper: :outlook_calendar_oauth_helper
    }
  }

  @doc """
  Starts `provider`'s OAuth flow for `user_id` (a single-use PKCE flow, see
  `Tymeslot.Integrations.Shared.OAuth.PendingFlow`) and returns the
  authorisation URL to send the browser to, or an error naming what an
  operator has to configure.

  ## Options
    - `:return_to` — relative path to redirect to after the OAuth callback
    - `:login_hint`, `:integration_id` — target the account already
      connected when reconnecting
  """
  @spec initiate(provider(), user_id(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def initiate(provider, user_id, opts \\ []) when is_integer(user_id) do
    %{label: label} = Map.fetch!(@providers, provider)

    case PendingFlow.start(user_id, provider) do
      {:ok, flow} ->
        url_opts = Keyword.put(opts, :pkce, flow)
        {:ok, url_helper(provider).authorization_url(user_id, redirect_uri(provider), url_opts)}

      {:error, _changeset} ->
        {:error, "Failed to setup #{label} OAuth"}
    end
  rescue
    error ->
      %{label: label, config: config} = Map.fetch!(@providers, provider)
      {:error, OAuthConfig.setup_error_message(config, label, error)}
  end

  @doc """
  Completes an OAuth callback for `user_id`, the signed-in user: verifies the
  state was issued to that user, consumes the flow it names (once), exchanges
  the code with that flow's PKCE verifier, and creates or updates their
  calendar integration. Nothing is sent to the provider until the state and
  the flow have both checked out.
  """
  @spec complete(provider(), String.t(), String.t(), user_id()) ::
          {:ok, CalendarIntegrationSchema.t()} | {:error, term()}
  def complete(provider, code, state, user_id) do
    %{config: config, helper: helper} = Map.fetch!(@providers, provider)

    with {:ok, validated} <- State.verify(state, config, user_id),
         {:ok, code_verifier} <- PendingFlow.consume(validated.nonce, user_id, provider) do
      helper.handle_callback(
        code,
        redirect_uri(provider),
        Map.put(validated, :code_verifier, code_verifier)
      )
    end
  end

  @doc """
  Initiate a Google scope upgrade for an existing integration.
  Returns {:ok, url} or {:error, reason}.
  """
  @spec initiate_google_scope_upgrade(user_id(), pos_integer()) ::
          {:ok, String.t()} | {:error, any()}
  def initiate_google_scope_upgrade(user_id, integration_id)
      when is_integer(user_id) and is_integer(integration_id) do
    with {:ok, integration} <- Management.get_calendar_integration(integration_id, user_id),
         true <- integration.provider == "google",
         {:ok, url} <- initiate(:google, user_id) do
      {:ok, url}
    else
      false -> {:error, :invalid_provider}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Check if a Google integration needs scope upgrade.
  """
  @spec needs_scope_upgrade?(CalendarIntegrationSchema.t()) :: boolean()
  def needs_scope_upgrade?(integration) do
    integration.provider == "google" && GoogleProvider.needs_scope_upgrade?(integration)
  end

  # The authorisation request and the code exchange must name the same URI, so
  # both are built here.
  defp redirect_uri(provider) when is_map_key(@providers, provider),
    do: "#{Endpoint.url()}/auth/#{provider}/calendar/callback"

  defp url_helper(provider) do
    %{helper: helper, url_helper: key} = Map.fetch!(@providers, provider)
    Application.get_env(:tymeslot, key, helper)
  end
end
