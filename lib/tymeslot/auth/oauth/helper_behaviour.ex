defmodule Tymeslot.Auth.OAuth.HelperBehaviour do
  @moduledoc """
  Behaviour for OAuth Helper to allow mocking in tests.
  """

  @callback build_oauth_client(atom(), String.t(), String.t()) :: OAuth2.Client.t()
  @callback build_oauth_client(atom(), String.t()) :: OAuth2.Client.t()
  @callback exchange_code_for_token(OAuth2.Client.t(), String.t()) ::
              {:ok, OAuth2.Client.t()} | {:error, any()}
  @callback get_user_info(OAuth2.Client.t(), atom()) :: {:ok, map()} | {:error, any()}
  @callback get_github_user_emails(OAuth2.Client.t()) :: {:ok, [map()]} | {:error, any()}
  @callback generate_and_store_state(Plug.Conn.t()) :: {Plug.Conn.t(), String.t()}
  @callback validate_state(Plug.Conn.t(), String.t() | nil) :: :ok | {:error, :invalid_state}
  @callback clear_oauth_state(Plug.Conn.t()) :: Plug.Conn.t()
  @callback get_callback_url(atom()) :: String.t()
  @callback get_full_callback_url_from_conn(Plug.Conn.t(), String.t()) :: String.t()
  @callback process_user(atom(), map()) :: {:ok, map()} | {:error, any()}
  @callback registration_complete?(atom(), map()) :: boolean()
  @callback check_oauth_requirements(atom(), map()) :: {:missing, list(atom())} | :complete
  @callback find_existing_user(atom(), map()) :: {:ok, map()} | {:error, :not_found}
  @callback create_oauth_user(atom(), map(), map(), keyword()) :: {:ok, map()} | {:error, any()}
  @callback update_client_headers(OAuth2.Client.t(), atom()) :: OAuth2.Client.t()
  @callback parse_access_token(String.t()) :: String.t()

  @type flow_result ::
          {:ok, Plug.Conn.t(), atom()}
          | {:registration_required, Plug.Conn.t(), atom(), map()}
          | {:error, :invalid_state, Plug.Conn.t()}
          | {:error, :oauth_error, atom(), Plug.Conn.t()}
          | {:error, :general_error, atom(), Plug.Conn.t()}
          | {:error, :session_failed, atom(), Plug.Conn.t()}
          | {:error, :registration_disabled, atom(), Plug.Conn.t()}

  @callback handle_oauth_callback(Plug.Conn.t(), map()) :: flow_result()
end

defmodule Tymeslot.Auth.OAuth.ProviderBehaviour do
  @moduledoc """
  Behaviour for OAuth providers (GitHub, Google, OAuth etc.).
  """
  @callback authorize_url(Plug.Conn.t(), String.t()) :: {Plug.Conn.t(), String.t()}
  @callback handle_callback(Plug.Conn.t(), String.t(), String.t(), String.t()) ::
              Plug.Conn.t()
  @callback process_user(map()) :: {:ok, map()} | {:error, any()}
  @callback registration_complete?(map()) :: boolean()
  @callback get_callback_url() :: String.t()
end
