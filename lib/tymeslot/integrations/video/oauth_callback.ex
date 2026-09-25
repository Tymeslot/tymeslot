defmodule Tymeslot.Integrations.Video.OAuthCallback do
  @moduledoc """
  The second half of the OAuth flow for video providers: turning the code a
  provider hands back into a connected integration.

  Google Meet, Microsoft Teams and Zoom share one path (exchange the code,
  check the grant carries what the provider needs, then create or reconnect
  the integration); the table below and two small clauses hold everything
  that differs between them.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Tymeslot.Dashboard.DashboardContext
  alias Tymeslot.Integrations.Common.OAuth.AccountMatch
  alias Tymeslot.Integrations.Google.GoogleOAuthHelper
  alias Tymeslot.Integrations.Video.OAuth
  alias Tymeslot.Integrations.Video.ProviderConfig
  alias Tymeslot.Integrations.Video.Reconnect
  alias Tymeslot.Integrations.Video.Teams.TeamsOAuthHelper
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Integrations.Video.Zoom.ZoomOAuthHelper

  # Every helper exchanges with the same `(code, redirect_uri, state)` shape and
  # verifies the signed state itself, returning the state's user and integration
  # alongside the tokens.
  @exchange_helpers %{
    google_meet: GoogleOAuthHelper,
    teams: TeamsOAuthHelper,
    zoom: ZoomOAuthHelper
  }

  @doc """
  Completes an OAuth callback: exchanges the code, checks the grant, and
  creates or reconnects the user's integration for `provider`.

  On success the user's cached dashboard integration status is invalidated, so
  the dashboard reflects the new connection straight away rather than after the
  cache expires. Besides the helpers' own errors, fails with
  `:missing_teams_fields` or `:missing_zoom_account_id` when a Teams or Zoom
  grant lacks the account details the provider's API calls need.
  """
  @spec complete(OAuth.provider(), String.t(), String.t()) ::
          {:ok, VideoIntegrationSchema.t()} | {:error, term()}
  def complete(provider, code, state) do
    helper = Map.fetch!(@exchange_helpers, provider)

    with {:ok, tokens} <-
           helper.exchange_code_for_tokens(code, OAuth.redirect_uri(provider), state),
         :ok <- validate_tokens(provider, tokens),
         {:ok, integration} <- persist(provider, tokens) do
      DashboardContext.invalidate_integration_status(tokens.user_id)
      {:ok, integration}
    end
  end

  defp validate_tokens(:teams, tokens) do
    if tokens[:tenant_id] && tokens[:teams_user_id] do
      :ok
    else
      Logger.error("Teams OAuth tokens missing required fields: tenant_id or teams_user_id",
        has_tenant_id: not is_nil(tokens[:tenant_id]),
        has_teams_user_id: not is_nil(tokens[:teams_user_id]),
        user_id: tokens[:user_id]
      )

      {:error, :missing_teams_fields}
    end
  end

  defp validate_tokens(:zoom, %{provider_account_id: id}) when is_binary(id) and id != "",
    do: :ok

  defp validate_tokens(:zoom, _tokens), do: {:error, :missing_zoom_account_id}
  defp validate_tokens(:google_meet, _tokens), do: :ok

  defp persist(provider, tokens) do
    token_attrs =
      Map.merge(
        %{
          access_token: tokens.access_token,
          refresh_token: tokens.refresh_token,
          token_expires_at: tokens.expires_at,
          oauth_scope: tokens.scope,
          is_active: true,
          provider_account_id: tokens[:provider_account_id],
          provider_account_email: tokens[:provider_account_email]
        },
        provider_attrs(provider, tokens)
      )

    match_or_create(
      tokens.user_id,
      Atom.to_string(provider),
      ProviderConfig.display_name(provider),
      tokens[:provider_account_id],
      tokens[:integration_id],
      token_attrs
    )
  end

  # Teams calls Graph on behalf of a specific tenant and user, so it keeps both
  # beside the tokens.
  defp provider_attrs(:teams, tokens),
    do: %{tenant_id: tokens.tenant_id, teams_user_id: tokens.teams_user_id}

  defp provider_attrs(_provider, _tokens), do: %{}

  @doc """
  Creates or updates an OAuth video integration from callback token data.

  Handles three scenarios:
  1. Re-authorization of a specific integration (integration_id present)
  2. New connection with a known account (provider_account_id present)
  3. Legacy fallback — match by user + provider

  An OAuth callback proves the grant, so every update of an existing row goes
  through `Tymeslot.Integrations.Video.Reconnect`, which catches the rooms up
  on what they missed while the integration needed reconnecting.
  """
  @spec match_or_create(
          pos_integer(),
          String.t(),
          String.t(),
          String.t() | nil,
          pos_integer() | nil,
          map()
        ) :: {:ok, VideoIntegrationSchema.t()} | {:error, any()}
  def match_or_create(
        user_id,
        provider,
        name,
        provider_account_id,
        integration_id,
        token_attrs
      ) do
    cond do
      integration_id ->
        reauthorize_existing(user_id, integration_id, provider_account_id, token_attrs)

      is_binary(provider_account_id) ->
        match_or_create_by_account(user_id, provider, name, provider_account_id, token_attrs)

      true ->
        fallback_match_or_create(user_id, provider, name, token_attrs)
    end
  end

  defp reauthorize_existing(user_id, integration_id, provider_account_id, token_attrs) do
    case VideoIntegrationQueries.get_for_user(integration_id, user_id) do
      {:ok, existing} ->
        AccountMatch.verify_account_match(existing, provider_account_id, fn ->
          Reconnect.save(existing, token_attrs)
        end)

      {:error, :not_found} ->
        {:error, "Integration not found"}

      {:error, :requires_reencryption, existing} ->
        # Credentials are stale but the user is reconnecting — allow the update
        # so fresh credentials replace the undecryptable ones.
        AccountMatch.verify_account_match(existing, provider_account_id, fn ->
          Reconnect.save(existing, token_attrs)
        end)
    end
  end

  defp match_or_create_by_account(user_id, provider, name, provider_account_id, token_attrs) do
    case VideoIntegrationQueries.get_by_account_for_user(user_id, provider, provider_account_id) do
      {:ok, existing} ->
        Reconnect.save(existing, token_attrs)

      {:error, :not_found} ->
        reactivate_or_create_video(user_id, provider, name, provider_account_id, token_attrs)
    end
  end

  defp reactivate_or_create_video(user_id, provider, name, provider_account_id, token_attrs) do
    reactivation_attrs = Map.put(token_attrs, :is_active, true)
    create_attrs = Map.merge(token_attrs, %{user_id: user_id, name: name, provider: provider})

    AccountMatch.find_or_create_with_reactivation(
      fn ->
        VideoIntegrationQueries.get_any_by_account_for_user(
          user_id,
          provider,
          provider_account_id
        )
      end,
      fn existing -> Reconnect.save(existing, reactivation_attrs) end,
      fn ->
        AccountMatch.create_with_race_protection(
          fn -> VideoIntegrationQueries.create(create_attrs) end,
          fn ->
            VideoIntegrationQueries.get_by_account_for_user(
              user_id,
              provider,
              provider_account_id
            )
          end,
          fn existing -> Reconnect.save(existing, token_attrs) end
        )
      end
    )
  end

  defp fallback_match_or_create(user_id, provider, name, token_attrs) do
    Logger.warning(
      "OAuth callback missing provider_account_id — using legacy per-provider match",
      user_id: user_id,
      provider: provider
    )

    case VideoIntegrationQueries.get_by_provider_for_user(user_id, provider) do
      {:ok, _existing} ->
        # User already has integration(s) for this provider but we can't identify
        # which account this callback belongs to. Reject to avoid silently overwriting.
        {:error,
         dgettext(
           "dashboard_integrations",
           "Could not identify your account. Please try again. If the problem persists, remove and re-add the integration."
         )}

      {:error, :not_found} ->
        VideoIntegrationQueries.create(
          Map.merge(token_attrs, %{user_id: user_id, name: name, provider: provider})
        )
    end
  end
end
