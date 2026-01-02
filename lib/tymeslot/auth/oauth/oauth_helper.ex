defmodule Tymeslot.Auth.OAuth.Helper do
  @moduledoc """
  Provides helper functions for OAuth2 authentication flows (GitHub, Google).

  This module is being gradually refactored into smaller, focused modules.
  The public API is preserved; implementations delegate to:
  - Tymeslot.Auth.OAuth.State
  - Tymeslot.Auth.OAuth.URLs
  - Tymeslot.Auth.OAuth.Client
  """
  require Logger
  alias OAuth2.Response
  alias Phoenix.Controller
  alias Tymeslot.Auth.OAuth.{Client, State, URLs}
  alias Tymeslot.Auth.Session
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Deployment

  @type provider :: :github | :google
  @type oauth_client :: OAuth2.Client.t()
  @type conn :: map()

  @doc """
  Builds an OAuth2 client for the specified provider with state parameter.
  """
  @spec build_oauth_client(provider, String.t(), String.t()) :: oauth_client
  def build_oauth_client(provider, redirect_uri, state) when provider in [:github, :google] do
    Client.build(provider, redirect_uri, state)
  end

  @doc """
  Builds an OAuth2 client for the specified provider (legacy function without state).

  This function is kept for backward compatibility but should be avoided.
  Use build_oauth_client/3 with state parameter instead.
  """
  @spec build_oauth_client(provider, String.t()) :: oauth_client
  def build_oauth_client(provider, redirect_uri) do
    Logger.warning("OAuth client built without state parameter - this is insecure!")
    build_oauth_client(provider, redirect_uri, "")
  end

  @doc """
  Exchange code for access token.
  """
  @spec exchange_code_for_token(oauth_client, String.t()) :: {:ok, oauth_client} | {:error, any()}
  def exchange_code_for_token(client, code) do
    Client.exchange_code_for_token(client, code)
  end

  @doc """
  Fetches user info from the OAuth provider.
  """
  @spec get_user_info(oauth_client, provider) :: {:ok, map()} | {:error, any()}
  def get_user_info(client, :github) do
    client = Client.with_auth_header(client, :github)

    case OAuth2.Client.get(client, "https://api.github.com/user") do
      {:ok, %Response{body: body}} -> decode_oauth_body(body)
      err -> err
    end
  end

  def get_user_info(client, :google) do
    client = Client.with_auth_header(client, :google)

    case OAuth2.Client.get(client, "https://www.googleapis.com/oauth2/v1/userinfo") do
      {:ok, %Response{body: body}} -> decode_oauth_body(body)
      err -> err
    end
  end

  @doc """
  Fetches user emails from GitHub when not provided in basic user info.
  """
  @spec get_github_user_emails(oauth_client) :: {:ok, [map()]} | {:error, any()}
  def get_github_user_emails(client) do
    client = Client.with_auth_header(client, :github)

    case OAuth2.Client.get(client, "https://api.github.com/user/emails") do
      {:ok, %Response{body: body}} -> parse_user_emails_body(body)
      err -> err
    end
  end

  @spec update_client_headers(oauth_client, provider) :: oauth_client
  def update_client_headers(client, provider) when provider in [:github, :google] do
    Client.with_auth_header(client, provider)
  end

  @doc """
  Parse access token from JSON or return as-is.
  """
  @spec parse_access_token(String.t()) :: String.t()
  def parse_access_token(json_string), do: Client.parse_access_token(json_string)

  # Accept both JSON strings and already-decoded maps from OAuth2 client responses
  @spec decode_oauth_body(any()) :: {:ok, map()} | {:error, any()}
  defp decode_oauth_body(body) when is_binary(body) do
    Jason.decode(body)
  end

  defp decode_oauth_body(body) when is_map(body), do: {:ok, body}
  defp decode_oauth_body(other), do: {:error, {:unexpected_body, other}}

  # Provider configuration now lives in Tymeslot.Auth.OAuth.Client

  @doc """
  Returns the callback URL for the given OAuth provider.
  """
  @spec get_callback_url(:github | :google) :: String.t()
  def get_callback_url(provider) when provider in [:github, :google],
    do: URLs.callback_path(provider)

  @doc """
  Processes the user info returned from the OAuth provider and returns a user map.
  """
  @spec process_user(:github | :google, map()) :: {:ok, map()} | {:error, any()}
  def process_user(:github, %{"id" => github_user_id} = user_info) do
    # GitHub may not provide email in /user endpoint if user has private email
    # Try to get email from user_info first, then fetch from /user/emails if needed
    email =
      case Map.get(user_info, "email") do
        nil -> nil
        "" -> nil
        email when is_binary(email) -> email
      end

    # Mark if email came from provider (will be used for auto-verification)
    email_from_provider = email != nil and String.trim(email) != ""

    user = %{
      email: email,
      github_user_id: github_user_id,
      name: Map.get(user_info, "name"),
      is_verified: true,
      email_from_provider: email_from_provider
    }

    {:ok, user}
  end

  def process_user(:google, %{"email" => email, "id" => google_user_id} = user_info) do
    user = %{
      email: email,
      google_user_id: google_user_id,
      name: Map.get(user_info, "name"),
      is_verified: true,
      # Google always provides email
      email_from_provider: true
    }

    {:ok, user}
  end

  def process_user(_, _), do: {:error, :invalid_user_info}

  @doc """
  Checks if the registration is complete for the given provider and user.
  """
  @spec registration_complete?(:github | :google, map()) :: boolean()
  def registration_complete?(:github, %{email: email, github_user_id: id})
      when is_binary(email) and is_binary(id),
      do: true

  def registration_complete?(:google, %{email: email, google_user_id: id})
      when is_binary(email) and is_binary(id),
      do: true

  def registration_complete?(_, _), do: false

  defp parse_user_emails_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, list} when is_list(list) -> {:ok, list}
      {:ok, _other} -> {:error, {:unexpected_body, body}}
      {:error, %Jason.DecodeError{} = err} -> {:error, err}
    end
  end

  defp parse_user_emails_body(body) when is_list(body), do: {:ok, body}
  defp parse_user_emails_body(other), do: {:error, {:unexpected_body, other}}

  @doc """
  Determines what information is missing for OAuth registration completion.
  Returns {:missing, [:email | :terms]} or :complete.
  """
  @spec check_oauth_requirements(:github | :google, map()) :: {:missing, list(atom())} | :complete
  def check_oauth_requirements(_provider, user) do
    missing = []

    # Check if email is missing or invalid
    missing =
      if is_binary(user.email) and String.length(String.trim(user.email)) > 0 do
        missing
      else
        [:email | missing]
      end

    # Only require terms acceptance for new registrations if main deployment
    missing =
      if Deployment.main?() do
        [:terms | missing]
      else
        missing
      end

    {:missing, Enum.reverse(missing)}
  end

  @doc """
  Handles OAuth callback in a Phoenix controller with state validation.

  This function provides a complete workflow for OAuth callback handling, including:
  - Validating the OAuth2 state parameter to prevent CSRF attacks
  - Exchanging the authorization code for a token
  - Fetching user information from the provider
  - Creating a session if the user is fully registered
  - Redirecting to registration completion if needed
  - Handling errors appropriately

  ## Parameters
    - conn: Plug.Conn.t()
    - code: String.t() - The OAuth authorization code
    - state: String.t() | nil - The OAuth state parameter
    - provider: :github | :google - The OAuth provider
    - opts: Keyword list of options

  ## Options
    - :success_path - Path to redirect on success (default: "/")
    - :login_path - Path to redirect on failure (default: "/auth/login")
    - :registration_path - Path for completing registration (default: "/complete-registration")

  ## Returns
    - Plug.Conn.t() with appropriate redirects and flash messages
  """
  @spec handle_oauth_callback(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def handle_oauth_callback(conn, %{code: code, state: state, provider: provider} = params) do
    opts = Map.get(params, :opts, [])

    context = %{
      code: code,
      provider: provider,
      success_path: Keyword.get(opts, :success_path, "/"),
      login_path: Keyword.get(opts, :login_path, "/auth/login"),
      registration_path: Keyword.get(opts, :registration_path, "/auth/complete-registration")
    }

    conn
    |> validate_oauth_state(state, context)
    |> process_oauth_response(context)
    |> complete_oauth_flow(context)
  end

  # Validates OAuth state parameter and clears it from session.
  defp validate_oauth_state(conn, state, context) do
    case validate_state(conn, state) do
      :ok ->
        clear_oauth_state(conn)

      {:error, :invalid_state} ->
        {:error, handle_invalid_state(conn, context.login_path)}
    end
  end

  # Processes OAuth response by exchanging code for token and fetching user info.
  defp process_oauth_response({:error, conn}, _context), do: {:error, conn}

  defp process_oauth_response(conn, %{code: code, provider: provider} = context) do
    full_callback_url = get_full_callback_url_from_conn(conn, get_callback_url(provider))
    client = build_oauth_client(provider, full_callback_url, "")

    with {:ok, client} <- exchange_code_for_token(client, code),
         {:ok, user_info} <- get_user_info(client, provider),
         {:ok, user} <- process_user(provider, user_info),
         enhanced_user <- enhance_user_data(provider, user, client) do
      {conn, enhanced_user}
    else
      {:error, %OAuth2.Error{} = error} ->
        {:error, handle_oauth_error(conn, provider, error, context.login_path)}

      {:error, reason} ->
        {:error, handle_general_error(conn, provider, reason, context.login_path)}
    end
  end

  # Completes OAuth flow by finding/creating user and establishing session.
  defp complete_oauth_flow({:error, conn}, _context), do: conn

  defp complete_oauth_flow({conn, user}, context) do
    auth_context = Map.merge(context, %{user: user})
    handle_user_authentication(conn, auth_context)
  end

  defp enhance_user_data(:github, %{email: email} = user, client)
       when is_nil(email) or email == "" do
    case get_github_user_emails(client) do
      {:ok, emails} when is_list(emails) ->
        add_github_email_to_user(user, emails)

      {:error, _reason} ->
        Map.put(user, :email_from_provider, false)
    end
  end

  defp enhance_user_data(_provider, user, _client) do
    case Map.get(user, :email_from_provider) do
      nil ->
        email_provided =
          case user.email do
            nil -> false
            "" -> false
            email when is_binary(email) -> String.trim(email) != ""
          end

        Map.put(user, :email_from_provider, email_provided)

      _ ->
        user
    end
  end

  defp add_github_email_to_user(user, emails) do
    primary_email = find_primary_email(emails)
    verified_email = primary_email || find_verified_email(emails)

    case extract_email_address(primary_email, verified_email) do
      {:ok, email} -> %{user | email: email, email_from_provider: true}
      :error -> Map.put(user, :email_from_provider, false)
    end
  end

  defp find_primary_email(emails) do
    Enum.find(emails, fn email ->
      Map.get(email, "primary", false) && Map.get(email, "verified", false)
    end)
  end

  defp find_verified_email(emails) do
    Enum.find(emails, fn email ->
      Map.get(email, "verified", false)
    end)
  end

  defp extract_email_address(%{"email" => email}, _) when is_binary(email), do: {:ok, email}
  defp extract_email_address(_, %{"email" => email}) when is_binary(email), do: {:ok, email}
  defp extract_email_address(_, _), do: :error

  defp handle_user_authentication(
         conn,
         %{
           provider: provider,
           user: user,
           success_path: _success_path,
           login_path: _login_path,
           registration_path: registration_path
         } = context
       ) do
    case find_existing_user(provider, user) do
      {:ok, existing_user} ->
        session_context = Map.put(context, :user, existing_user)
        create_user_session(conn, session_context)

      {:error, :not_found} ->
        handle_new_user_registration(conn, provider, user, registration_path)
    end
  end

  defp create_user_session(conn, %{
         user: user,
         provider: provider,
         success_path: success_path,
         login_path: login_path
       }) do
    case Session.create_session(conn, %{id: user.id}) do
      {:ok, conn, _token} ->
        conn
        |> Controller.put_flash(:info, "Successfully signed in with #{provider_name(provider)}.")
        |> Controller.redirect(to: success_path)

      {:error, reason, _message} ->
        Logger.error("Failed to create session after #{provider} auth: #{inspect(reason)}")

        conn
        |> Controller.put_flash(:error, "Authentication succeeded but session creation failed.")
        |> Controller.redirect(to: login_path)
    end
  end

  defp handle_new_user_registration(conn, provider, user, registration_path) do
    {:missing, missing_fields} = check_oauth_requirements(provider, user)
    params = build_modal_params(provider, user, missing_fields)
    query_params = URI.encode_query(params)
    Controller.redirect(conn, to: "#{registration_path}?#{query_params}")
  end

  defp handle_invalid_state(conn, login_path) do
    Logger.warning(
      "OAuth callback received with invalid or missing state parameter - potential CSRF attack"
    )

    conn
    |> Controller.put_flash(:error, "Security validation failed. Please try again.")
    |> Controller.redirect(to: login_path)
  end

  defp handle_oauth_error(conn, provider, error, login_path) do
    Logger.error("#{provider_name(provider)} OAuth error: #{inspect(error)}")

    conn
    |> Controller.put_flash(:error, "Failed to authenticate with #{provider_name(provider)}.")
    |> Controller.redirect(to: login_path)
  end

  defp handle_general_error(conn, provider, reason, login_path) do
    Logger.error("#{provider_name(provider)} authentication error: #{inspect(reason)}")

    conn
    |> Controller.put_flash(
      :error,
      "An error occurred during #{provider_name(provider)} authentication."
    )
    |> Controller.redirect(to: login_path)
  end

  @doc """
  Legacy OAuth callback handler with 5 parameters.

  This function is kept for backward compatibility but should be avoided.
  Use handle_oauth_callback/2 with params map instead.
  """
  @spec handle_oauth_callback(
          Plug.Conn.t(),
          String.t(),
          String.t() | nil,
          :github | :google,
          keyword()
        ) ::
          Plug.Conn.t()
  # credo:disable-for-next-line Credo.Check.Refactor.FunctionArity
  def handle_oauth_callback(conn, code, state, provider, opts) do
    params = %{
      code: code,
      state: state,
      provider: provider,
      opts: opts
    }

    handle_oauth_callback(conn, params)
  end

  @doc """
  Legacy OAuth callback handler without state validation.

  This function is kept for backward compatibility but should be avoided.
  Use handle_oauth_callback/2 with params map including state parameter validation instead.
  """
  @spec handle_oauth_callback(Plug.Conn.t(), String.t(), :github | :google, keyword()) ::
          Plug.Conn.t()
  def handle_oauth_callback(conn, code, provider, opts) do
    Logger.warning("OAuth callback handled without state validation - this is insecure!")

    params = %{
      code: code,
      state: nil,
      provider: provider,
      opts: opts
    }

    handle_oauth_callback(conn, params)
  end

  # Helper functions for OAuth callback handling

  @spec provider_name(:github | :google) :: String.t()
  defp provider_name(:github), do: "GitHub"
  defp provider_name(:google), do: "Google"

  @spec build_modal_params(:github | :google, map(), list(atom())) :: map()
  defp build_modal_params(provider, user, missing_fields) do
    base_params = %{
      "auth" => "oauth_complete",
      "oauth_provider" => to_string(provider),
      "oauth_missing" => Enum.join(missing_fields, ",")
    }

    # Mark whether email came from provider or needs to be entered by user
    # OAuth providers that give us an email should be marked as email_from_provider: true
    email_from_provider = user.email != nil and String.trim(user.email) != ""

    oauth_data =
      case provider do
        :github ->
          %{
            "oauth_email" => user.email || "",
            "oauth_verified" => to_string(user.is_verified),
            "oauth_email_from_provider" => to_string(email_from_provider),
            "oauth_github_id" => user.github_user_id,
            "oauth_name" => user.name || ""
          }

        :google ->
          %{
            "oauth_email" => user.email || "",
            "oauth_verified" => to_string(user.is_verified),
            "oauth_email_from_provider" => to_string(email_from_provider),
            "oauth_google_id" => user.google_user_id,
            "oauth_name" => user.name || ""
          }
      end

    Map.merge(base_params, oauth_data)
  end

  @doc """
  Generates a secure OAuth2 state parameter and stores it in the session.

  Returns a tuple containing the updated connection and the generated state.
  """
  @spec generate_and_store_state(Plug.Conn.t()) :: {Plug.Conn.t(), String.t()}
  def generate_and_store_state(conn), do: State.generate_and_store_state(conn)

  @doc """
  Validates the OAuth2 state parameter against the stored session value.

  Returns :ok if valid, {:error, :invalid_state} if invalid or missing.
  """
  @spec validate_state(Plug.Conn.t(), String.t() | nil) :: :ok | {:error, :invalid_state}
  def validate_state(conn, received_state), do: State.validate_state(conn, received_state)

  @doc """
  Clears the OAuth state from the session after validation.
  """
  @spec clear_oauth_state(Plug.Conn.t()) :: Plug.Conn.t()
  def clear_oauth_state(conn), do: State.clear_oauth_state(conn)

  @doc """
  Builds a full callback URL from the connection and relative path.

  This ensures the redirect_uri used in token exchange matches the one used in authorization.
  """
  @spec get_full_callback_url_from_conn(Plug.Conn.t(), String.t()) :: String.t()
  def get_full_callback_url_from_conn(conn, relative_path),
    do: URLs.callback_url(conn, relative_path)

  @doc """
  Finds an existing user in the database by OAuth provider information.
  """
  @spec find_existing_user(:github | :google, map()) :: {:ok, map()} | {:error, :not_found}
  def find_existing_user(:github, %{email: email, github_user_id: github_id}) do
    user_queries = Config.user_queries_module()
    github_id_int = normalize_github_id(github_id)

    find_user_by_id_or_email(
      user_queries,
      &user_queries.get_user_by_github_id/1,
      github_id_int,
      email
    )
  end

  def find_existing_user(:google, %{email: email, google_user_id: google_id}) do
    user_queries = Config.user_queries_module()

    find_user_by_id_or_email(
      user_queries,
      &user_queries.get_user_by_google_id/1,
      google_id,
      email
    )
  end

  @doc """
  Creates a new user from OAuth provider information.
  """
  @spec create_oauth_user(:github | :google, map(), map()) :: {:ok, map()} | {:error, any()}
  def create_oauth_user(provider, oauth_user, profile_params \\ %{}) do
    placeholder_password = "$2b$12$oauth_user_no_password_placeholder_hash_not_for_authentication"
    email_verified = determine_email_verification_status(oauth_user)

    auth_params = build_auth_params(provider, oauth_user, email_verified, placeholder_password)
    # Use transactional user creation to prevent race conditions
    alias Tymeslot.Auth.OAuth.TransactionalUserCreation

    case TransactionalUserCreation.find_or_create_oauth_user(
           provider,
           auth_params,
           profile_params
         ) do
      {:ok, %{user: user, created: true}} ->
        # New user created
        handle_user_verification_status(user, email_verified, oauth_user.email)

      {:ok, %{user: user, created: false}} ->
        # Existing user found - check if this is an account linking scenario
        case check_oauth_account_linking(provider, user, oauth_user) do
          :should_link_account ->
            {:ok, user}

          :email_already_taken ->
            {:error, :email_already_taken}
        end

      {:error, reason} ->
        Logger.error("OAuth user creation failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @spec check_oauth_account_linking(:github | :google, map(), map()) ::
          :should_link_account | :email_already_taken
  defp check_oauth_account_linking(provider, user, oauth_user) do
    # Check if the user already has this OAuth provider linked
    case provider do
      :github ->
        if user.github_user_id == oauth_user.github_user_id do
          # Same user, same provider
          :should_link_account
        else
          # Different user trying to register with same email
          :email_already_taken
        end

      :google ->
        if user.google_user_id == oauth_user.google_user_id do
          # Same user, same provider
          :should_link_account
        else
          # Different user trying to register with same email
          :email_already_taken
        end
    end
  end

  defp determine_email_verification_status(%{email_from_provider: true}), do: true
  defp determine_email_verification_status(%{email_from_provider: false}), do: false

  defp determine_email_verification_status(oauth_user) do
    if oauth_user.email && String.trim(oauth_user.email) != "" do
      true
    else
      oauth_user.is_verified || false
    end
  end

  defp build_auth_params(:github, oauth_user, email_verified, placeholder_password) do
    %{
      "provider" => "github",
      "email" => oauth_user.email,
      "is_verified" => email_verified,
      "github_user_id" => oauth_user.github_user_id,
      "terms_accepted" => if(Deployment.main?(), do: "true", else: "false"),
      "hashed_password" => placeholder_password
    }
  end

  defp build_auth_params(:google, oauth_user, email_verified, placeholder_password) do
    %{
      "provider" => "google",
      "email" => oauth_user.email,
      "is_verified" => email_verified,
      "google_user_id" => oauth_user.google_user_id,
      "terms_accepted" => if(Deployment.main?(), do: "true", else: "false"),
      "hashed_password" => placeholder_password
    }
  end

  defp handle_user_verification_status(user, false, email) when not is_nil(email) do
    {:ok, Map.put(user, :needs_email_verification, true)}
  end

  defp handle_user_verification_status(user, _, _) do
    {:ok, user}
  end

  defp normalize_github_id(github_id) do
    case github_id do
      id when is_integer(id) -> id
      id when is_binary(id) -> String.to_integer(id)
      _ -> nil
    end
  end

  defp find_user_by_id_or_email(user_queries, id_lookup_fn, user_id, email) do
    if user_id do
      case id_lookup_fn.(user_id) do
        {:error, :not_found} ->
          find_user_by_email(user_queries, email)

        {:ok, user} ->
          {:ok, user}
      end
    else
      find_user_by_email(user_queries, email)
    end
  end

  defp find_user_by_email(user_queries, email) do
    if email && String.trim(email) != "" do
      user_queries.get_user_by_email(email)
    else
      {:error, :not_found}
    end
  end
end
