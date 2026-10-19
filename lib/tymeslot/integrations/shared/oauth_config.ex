defmodule Tymeslot.Integrations.Shared.OAuthConfig do
  @moduledoc """
  Reads the OAuth client credentials and secrets of the providers Tymeslot
  integrates with, in one way for all of them.

  A value comes from the provider's application config (`:google_oauth`,
  `:outlook_oauth`, `:zoom_oauth`) or else from its environment variable
  (`GOOGLE_CLIENT_ID`, `OUTLOOK_STATE_SECRET`, …), read at call time so a
  self-hoster can set it without a rebuild. A blank value counts as unset:
  an empty client secret is a misconfiguration, and an empty state secret
  would sign OAuth `state` with an empty HMAC key.

  It is also the behaviour a provider's config module implements so that
  `Tymeslot.Integrations.Shared.OAuth.TokenEndpoint.refresh_grant/4` can
  refresh against it.
  """

  @callback fetch_client_id() :: {:ok, String.t()} | {:error, String.t()}
  @callback fetch_client_secret() :: {:ok, String.t()} | {:error, String.t()}
  @callback token_url() :: String.t()

  @type provider :: :google | :microsoft | :zoom
  @type key :: :client_id | :client_secret | :state_secret | :deauth_secret

  # Microsoft's credentials keep the `outlook` names they were introduced
  # under; Teams reads the same ones.
  @providers %{
    google: %{config: :google_oauth, env: "GOOGLE", label: "Google"},
    microsoft: %{config: :outlook_oauth, env: "OUTLOOK", label: "Microsoft"},
    zoom: %{config: :zoom_oauth, env: "ZOOM", label: "Zoom"}
  }

  @keys %{
    client_id: %{env: "CLIENT_ID", label: "Client ID"},
    client_secret: %{env: "CLIENT_SECRET", label: "Client Secret"},
    state_secret: %{env: "STATE_SECRET", label: "State Secret"},
    deauth_secret: %{env: "DEAUTH_SECRET", label: "Deauth Secret"}
  }

  @doc """
  The environment variable a value is read from, e.g. `"GOOGLE_STATE_SECRET"`.
  """
  @spec env_var(provider(), key()) :: String.t()
  def env_var(provider, key), do: "#{@providers[provider].env}_#{@keys[key].env}"

  @doc """
  The configured value, or `nil` when it is unset or blank.
  """
  @spec get(provider(), key()) :: String.t() | nil
  def get(provider, key) when is_map_key(@providers, provider) and is_map_key(@keys, key) do
    configured = Application.get_env(:tymeslot, @providers[provider].config)[key]

    Enum.find([configured, System.get_env(env_var(provider, key))], &present?/1)
  end

  @doc """
  The configured value, or an error naming what is missing.
  """
  @spec fetch(provider(), key()) :: {:ok, String.t()} | {:error, String.t()}
  def fetch(provider, key) do
    case get(provider, key) do
      nil -> {:error, missing_message(provider, key)}
      value -> {:ok, value}
    end
  end

  @doc """
  The configured value; raises naming what is missing.
  """
  @spec fetch!(provider(), key()) :: String.t()
  def fetch!(provider, key) do
    case fetch(provider, key) do
      {:ok, value} -> value
      {:error, message} -> raise message
    end
  end

  @doc """
  The providers' state secret environment variables that are set but blank
  in `env`. Each counts as unset, so its provider is unconfigured;
  `config/runtime.exs` warns about them at boot in case one was meant to hold
  a value.
  """
  @spec blank_state_secrets(%{optional(String.t()) => String.t()}) :: [String.t()]
  def blank_state_secrets(env) do
    for provider <- Map.keys(@providers),
        name = env_var(provider, :state_secret),
        value = Map.get(env, name),
        is_binary(value) and not present?(value),
        do: name
  end

  @doc """
  The operator-facing message for a failure to start `provider`'s OAuth flow
  under the brand `label`. A missing setting is answered with the
  environment variables to set; anything else with the error itself.
  """
  @spec setup_error_message(provider(), String.t(), Exception.t()) :: String.t()
  def setup_error_message(provider, label, %RuntimeError{message: message} = error) do
    case Enum.find([:state_secret, :client_id, :client_secret], &missing?(message, &1)) do
      :state_secret ->
        "#{label} OAuth is not configured. Please set #{env_var(provider, :client_id)}, " <>
          "#{env_var(provider, :client_secret)}, and #{env_var(provider, :state_secret)} " <>
          "environment variables."

      nil ->
        generic_setup_error(label, error)

      key ->
        "#{label} OAuth is not configured. Please set #{env_var(provider, key)} environment variable."
    end
  end

  def setup_error_message(_provider, label, error), do: generic_setup_error(label, error)

  defp missing?(message, key),
    do: String.ends_with?(message, "#{@keys[key].label} not configured")

  defp generic_setup_error(label, error),
    do: "Failed to setup #{label} OAuth: #{Exception.message(error)}"

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  # "Google Client ID not configured": `Calendar.OAuth` and `Video.OAuth`
  # recognise the key from this wording to tell a self-hoster which variable
  # to set.
  defp missing_message(provider, key),
    do: "#{@providers[provider].label} #{@keys[key].label} not configured"
end
