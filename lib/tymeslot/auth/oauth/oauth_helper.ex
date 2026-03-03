defmodule Tymeslot.Auth.OAuth.Helper do
  @moduledoc """
  Provides helper functions for OAuth2 authentication flows.

  This module serves as a high-level API and orchestrator, delegating domain-specific
  concerns to focused sub-modules:
  - Tymeslot.Auth.OAuth.State: State generation and validation
  - Tymeslot.Auth.OAuth.URLs: URL generation
  - Tymeslot.Auth.OAuth.Client: OAuth2 client management
  - Tymeslot.Auth.OAuth.UserProcessor: User info processing and enhancement
  - Tymeslot.Auth.OAuth.UserRegistration: User finding and creation
  - Tymeslot.Auth.OAuth.FlowHandler: Controller flow orchestration
  """
  @behaviour Tymeslot.Auth.OAuth.HelperBehaviour
  require Logger

  alias Tymeslot.Auth.OAuth.{
    Client,
    FlowHandler,
    State,
    URLs,
    UserProcessor,
    UserRegistration
  }

  @type provider :: :github | :google | :oauth
  @type oauth_client :: OAuth2.Client.t()

  # --- Client & Token ---

  @impl Tymeslot.Auth.OAuth.HelperBehaviour
  def build_oauth_client(provider, redirect_uri, state) do
    Client.build(provider, redirect_uri, state)
  end

  @impl Tymeslot.Auth.OAuth.HelperBehaviour
  def build_oauth_client(provider, redirect_uri) do
    Logger.warning("OAuth client built without state parameter - this is insecure!")
    build_oauth_client(provider, redirect_uri, "")
  end

  @impl Tymeslot.Auth.OAuth.HelperBehaviour
  def exchange_code_for_token(client, code) do
    Client.exchange_code_for_token(client, code)
  end

  @impl Tymeslot.Auth.OAuth.HelperBehaviour
  def parse_access_token(json_string), do: Client.parse_access_token(json_string)

  @impl Tymeslot.Auth.OAuth.HelperBehaviour
  def update_client_headers(client, provider) do
    Client.with_auth_header(client, provider)
  end

  # --- User Info & Processing ---

  @impl Tymeslot.Auth.OAuth.HelperBehaviour
  def get_user_info(client, provider) do
    Client.get_user_info(client, provider)
  end

  @impl Tymeslot.Auth.OAuth.HelperBehaviour
  def get_github_user_emails(client) do
    # Delegating to UserProcessor which now handles this logic
    # But for the sake of the behaviour, we keep it here.
    client = Client.with_auth_header(client, :github)

    case OAuth2.Client.get(client, "https://api.github.com/user/emails") do
      {:ok, %OAuth2.Response{body: body}} -> decode_oauth_body(body)
      err -> err
    end
  end

  defp decode_oauth_body(body) when is_binary(body), do: Jason.decode(body)
  defp decode_oauth_body(body) when is_map(body), do: {:ok, body}
  defp decode_oauth_body(other), do: {:error, {:unexpected_body, other}}

  @impl Tymeslot.Auth.OAuth.HelperBehaviour
  def process_user(provider, user_info) do
    UserProcessor.process_user(provider, user_info)
  end

  # --- Registration & Requirements ---

  @impl Tymeslot.Auth.OAuth.HelperBehaviour
  def registration_complete?(provider, user) do
    UserRegistration.registration_complete?(provider, user)
  end

  @impl Tymeslot.Auth.OAuth.HelperBehaviour
  def check_oauth_requirements(provider, user) do
    UserRegistration.check_oauth_requirements(provider, user)
  end

  @impl Tymeslot.Auth.OAuth.HelperBehaviour
  def find_existing_user(provider, user) do
    UserRegistration.find_existing_user(provider, user)
  end

  @impl Tymeslot.Auth.OAuth.HelperBehaviour
  def create_oauth_user(provider, oauth_user, profile_params \\ %{}, opts \\ []) do
    UserRegistration.create_oauth_user(provider, oauth_user, profile_params, opts)
  end

  # --- State Management ---

  @impl Tymeslot.Auth.OAuth.HelperBehaviour
  def generate_and_store_state(conn), do: State.generate_and_store_state(conn)

  @impl Tymeslot.Auth.OAuth.HelperBehaviour
  def validate_state(conn, received_state), do: State.validate_state(conn, received_state)

  @impl Tymeslot.Auth.OAuth.HelperBehaviour
  def clear_oauth_state(conn), do: State.clear_oauth_state(conn)

  # --- URL Helpers ---

  @impl Tymeslot.Auth.OAuth.HelperBehaviour
  def get_callback_url(provider), do: URLs.callback_path(provider)

  @impl Tymeslot.Auth.OAuth.HelperBehaviour
  def get_full_callback_url_from_conn(conn, relative_path),
    do: URLs.callback_url(conn, relative_path)

  # --- Flow Handling ---

  @impl Tymeslot.Auth.OAuth.HelperBehaviour
  def handle_oauth_callback(conn, params) when is_map(params) do
    FlowHandler.handle_oauth_callback(conn, params)
  end

end
