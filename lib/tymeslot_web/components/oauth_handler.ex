defmodule TymeslotWeb.Live.OAuthHandler do
  @moduledoc """
  Shared OAuth handling for LiveView components.
  Centralizes OAuth redirect logic and reduces duplication.
  """

  alias Phoenix.Component
  alias TymeslotWeb.Helpers.IntegrationProviders

  @doc """
  Handle OAuth redirect for different providers and integration types
  """
  @spec handle_oauth_redirect(Phoenix.LiveView.Socket.t(), String.t(), atom()) ::
          Phoenix.LiveView.Socket.t()
  def handle_oauth_redirect(socket, provider, integration_type) do
    if IntegrationProviders.oauth_provider?(integration_type, provider) do
      # Send event to parent for redirect handling
      send(self(), {:oauth_redirect, provider, integration_type})
      Component.assign(socket, :show_provider_modal, false)
    else
      # Non-OAuth provider, just close modal
      Component.assign(socket, :show_provider_modal, false)
    end
  end

  @doc """
  Consolidated OAuth event handling with pattern matching
  """
  @spec handle_oauth_event(String.t(), atom()) ::
          {:oauth_redirect, String.t()} | {:error, String.t()}
  def handle_oauth_event(provider, integration_type) do
    case {provider, integration_type} do
      {"google", :calendar} ->
        {:oauth_redirect, "google_calendar"}

      {"outlook", :calendar} ->
        {:oauth_redirect, "outlook_calendar"}

      {"google_meet", :video} ->
        {:oauth_redirect, "google_meet"}

      {"teams", :video} ->
        {:oauth_redirect, "teams"}

      _ ->
        {:error, "Unknown OAuth provider: #{provider}"}
    end
  end

  @doc """
  Send OAuth redirect message to parent LiveView
  """
  @spec send_oauth_redirect(String.t(), atom()) :: :ok | {:error, String.t()}
  def send_oauth_redirect(provider, integration_type) do
    case handle_oauth_event(provider, integration_type) do
      {:oauth_redirect, redirect_provider} ->
        send(self(), {:oauth_redirect, redirect_provider})
        :ok

      {:error, _reason} = error ->
        error
    end
  end
end
