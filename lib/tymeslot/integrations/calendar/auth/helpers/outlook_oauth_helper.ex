defmodule Tymeslot.Integrations.Calendar.Outlook.OAuthHelper do
  @moduledoc """
  Helper module for Outlook/Microsoft Calendar OAuth flow.

  This module provides functions to generate OAuth URLs and handle
  the OAuth callback for Microsoft Graph API integration.
  """

  @behaviour Tymeslot.Integrations.Calendar.Auth.OAuthHelperBehaviour

  require Logger

  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.CallbackPersistence
  alias Tymeslot.Integrations.Shared.MicrosoftConfig
  alias Tymeslot.Integrations.Shared.OAuth.IdToken
  alias Tymeslot.Integrations.Shared.OAuth.PendingFlow
  alias Tymeslot.Integrations.Shared.OAuth.ProviderHelpers
  alias Tymeslot.Integrations.Shared.OAuth.State
  alias Tymeslot.Integrations.Shared.OAuth.TokenEndpoint
  alias Tymeslot.Workers.RefreshOutlookCalendarWorker

  @doc """
  Generates the OAuth authorization URL for Microsoft/Outlook Calendar.
  """
  @impl Tymeslot.Integrations.Calendar.Auth.OAuthHelperBehaviour
  @spec authorization_url(pos_integer(), String.t(), keyword()) :: String.t()
  def authorization_url(user_id, redirect_uri, options \\ []) do
    integration_id = Keyword.get(options, :integration_id)
    login_hint = Keyword.get(options, :login_hint)
    return_to = Keyword.get(options, :return_to)

    state =
      State.generate(user_id, MicrosoftConfig.state_secret(), integration_id,
        return_to: return_to,
        nonce: PendingFlow.nonce(options)
      )

    params =
      Map.merge(
        %{
          client_id: MicrosoftConfig.client_id!(),
          redirect_uri: redirect_uri,
          response_type: "code",
          scope: MicrosoftConfig.scope(),
          state: state,
          response_mode: "query",
          prompt: "select_account"
        },
        PendingFlow.challenge_params(options)
      )

    ProviderHelpers.build_authorization_url(MicrosoftConfig.authorize_url(), params, login_hint)
  end

  @doc """
  Handles the OAuth callback for the user `state` (already verified) names,
  and creates or updates their calendar integration.
  """
  @impl Tymeslot.Integrations.Calendar.Auth.OAuthHelperBehaviour
  @spec handle_callback(String.t(), String.t(), State.validated()) ::
          {:ok, CalendarIntegrationSchema.t()}
          | {:error, Tymeslot.Integrations.Calendar.Auth.OAuthHelperBehaviour.callback_error()}
  def handle_callback(
        code,
        redirect_uri,
        %{user_id: user_id, integration_id: integration_id} = flow
      ) do
    with {:ok, tokens} <-
           exchange_code_for_tokens(code, redirect_uri, code_verifier: flow[:code_verifier]),
         {:ok, integration} <-
           CallbackPersistence.upsert(
             "outlook",
             user_id,
             integration_id,
             with_account(tokens, user_id)
           ) do
      enqueue_initial_sync(integration)
      {:ok, integration}
    end
  end

  defp enqueue_initial_sync(integration) do
    # The worker already owns this path: a nil `graph_delta_link` makes it
    # bootstrap a delta baseline and opportunistically register the Graph
    # subscription. Enqueueing rather than seeding inline buys retries, and
    # keeps the OAuth callback free of a fire-and-forget supervised task.
    result =
      %{"calendar_integration_id" => integration.id}
      |> RefreshOutlookCalendarWorker.new()
      |> Oban.insert()

    case result do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to enqueue initial Outlook Calendar sync",
          integration_id: integration.id,
          error: LogFormat.reason(reason)
        )

        :ok
    end
  end

  @doc """
  Exchanges authorization code for access and refresh tokens.
  """
  @impl Tymeslot.Integrations.Calendar.Auth.OAuthHelperBehaviour
  @spec exchange_code_for_tokens(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, String.t()}
  def exchange_code_for_tokens(code, redirect_uri, opts \\ []) do
    with {:ok, client_id} <- MicrosoftConfig.fetch_client_id(),
         {:ok, client_secret} <- MicrosoftConfig.fetch_client_secret() do
      body =
        PendingFlow.verifier_param(opts, %{
          code: code,
          client_id: client_id,
          client_secret: client_secret,
          redirect_uri: redirect_uri,
          grant_type: "authorization_code",
          scope: MicrosoftConfig.scope()
        })

      case TokenEndpoint.exchange_code(MicrosoftConfig.token_url(), body,
             fallback_scope: MicrosoftConfig.scope(),
             log_context: [provider: :outlook]
           ) do
        {:ok, tokens} -> {:ok, tokens}
        {:error, error} -> {:error, TokenEndpoint.error_message(:exchange, error)}
      end
    end
  end

  # Private functions

  # The provider account the tokens belong to, from the id token's object id,
  # so a reconnect finds the integration already connected to that account.
  defp with_account(tokens, user_id) do
    {provider_account_id, provider_account_email} =
      case IdToken.decode(tokens[:id_token]) do
        {:ok, claims} ->
          {claims.oid, claims.email}

        {:error, reason} ->
          if tokens[:id_token] do
            Logger.warning(
              "Failed to decode Outlook id_token — account dedup falling back to legacy match",
              user_id: user_id,
              reason: LogFormat.reason(reason)
            )
          end

          {nil, nil}
      end

    Map.merge(tokens, %{
      provider_account_id: provider_account_id,
      provider_account_email: provider_account_email
    })
  end
end
