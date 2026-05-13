defmodule Tymeslot.Slack.OAuth do
  @moduledoc """
  Slack OAuth v2 helper.

  - Generates the authorize URL with a signed state token (CSRF protection).
  - Verifies the state token on callback.
  - Exchanges the code for a bot token via `Tymeslot.Slack.API`.
  """

  alias Tymeslot.Slack.API
  alias TymeslotWeb.Endpoint

  @scopes "chat:write,chat:write.public,channels:read,groups:read,team:read"
  @state_salt "slack_oauth_state"
  # 10 minutes
  @state_max_age 600

  @doc """
  Builds the URL to redirect a user to in order to install the Slack app.

  `user_id` is bound into the state token so the callback can verify the
  same user is finishing the flow it started.
  """
  @spec authorize_url(integer(), String.t()) :: String.t()
  def authorize_url(user_id, redirect_uri) do
    client_id = require_config!(:slack_client_id)
    state = Phoenix.Token.sign(Endpoint, @state_salt, user_id)

    query =
      URI.encode_query(%{
        client_id: client_id,
        scope: @scopes,
        redirect_uri: redirect_uri,
        state: state
      })

    "https://slack.com/oauth/v2/authorize?#{query}"
  end

  @doc """
  Verifies a state token returned by Slack.

  Returns `{:ok, user_id}` on success or `{:error, :expired_state}` /
  `{:error, :invalid_state}` on failure.
  """
  @spec verify_state(String.t()) ::
          {:ok, integer()} | {:error, :expired_state | :invalid_state}
  def verify_state(state) do
    case Phoenix.Token.verify(Endpoint, @state_salt, state, max_age: @state_max_age) do
      {:ok, user_id} -> {:ok, user_id}
      {:error, :expired} -> {:error, :expired_state}
      {:error, _reason} -> {:error, :invalid_state}
    end
  end

  @doc """
  Exchanges an OAuth code for installation info.

  Returns `{:ok, %{bot_token, team_id, team_name, authed_user_id, scope}}` on
  success or a tagged error from `Tymeslot.Slack.API.oauth_v2_access/4`.
  """
  @spec exchange_code(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def exchange_code(code, redirect_uri) do
    client_id = require_config!(:slack_client_id)
    client_secret = require_config!(:slack_client_secret)

    with {:ok, body} <- API.oauth_v2_access(client_id, client_secret, code, redirect_uri) do
      {:ok,
       %{
         bot_token: body["access_token"],
         team_id: get_in(body, ["team", "id"]),
         team_name: get_in(body, ["team", "name"]),
         authed_user_id: get_in(body, ["authed_user", "id"]),
         scope: body["scope"]
       }}
    end
  end

  defp require_config!(key) do
    case Application.get_env(:tymeslot, key) do
      nil -> raise "Slack OAuth not configured: missing #{key}"
      value -> value
    end
  end
end
