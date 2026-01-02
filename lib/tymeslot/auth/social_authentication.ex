defmodule Tymeslot.Auth.SocialAuthentication do
  @moduledoc """
  Handles social authentication for GitHub and Google.
  """

  require Logger

  alias Ecto.Changeset
  alias Plug.Conn
  alias Plug.Crypto
  alias Tymeslot.Auth.OAuth.TransactionalUserCreation

  @type provider :: String.t()
  @type user_info :: map()

  @doc """
  Generates and stores OAuth state parameter for CSRF protection.
  """
  @spec generate_oauth_state(Conn.t()) :: String.t()
  def generate_oauth_state(conn) do
    state = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    # Store state in session for validation
    conn
    |> Conn.put_session(:oauth_state, state)
    |> Conn.put_session(:oauth_state_expires, DateTime.add(DateTime.utc_now(), 600, :second))

    state
  end

  @doc """
  Validates OAuth state parameter to prevent CSRF attacks.
  """
  @spec validate_oauth_state(Conn.t(), String.t()) :: :ok | {:error, atom()}
  def validate_oauth_state(conn, provided_state) do
    stored_state = Conn.get_session(conn, :oauth_state)
    expires_at = Conn.get_session(conn, :oauth_state_expires)

    cond do
      is_nil(stored_state) or is_nil(expires_at) ->
        {:error, :missing_oauth_state}

      DateTime.compare(DateTime.utc_now(), expires_at) == :gt ->
        {:error, :oauth_state_expired}

      not Crypto.secure_compare(stored_state, provided_state || "") ->
        {:error, :invalid_oauth_state}

      true ->
        # Clear state after successful validation
        conn
        |> Conn.delete_session(:oauth_state)
        |> Conn.delete_session(:oauth_state_expires)

        :ok
    end
  end

  @doc """
  Validates provider response to ensure required fields are present.
  """
  @spec validate_provider_response(map()) :: :ok | {:error, atom(), any()}
  def validate_provider_response(auth_params) do
    required_fields = ["email", "provider"]

    with :ok <- validate_required_fields(auth_params, required_fields),
         :ok <- validate_email_verification(auth_params),
         :ok <- validate_provider_name(auth_params["provider"]) do
      :ok
    else
      error -> error
    end
  end

  @doc """
  Finalizes the social login registration process.

  ## Parameters
  - auth_params: A map containing authentication parameters
  - profile_params: A map containing profile parameters
  - temp_user: A map containing temporary user information

  ## Returns
  - {:ok, user, message} if registration is successful
  - {:error, reason, details} if there was an error
  """
  @spec finalize_social_login_registration(map(), map(), map()) ::
          {:ok, map(), String.t()} | {:error, atom(), any()}
  def finalize_social_login_registration(auth_params, profile_params, temp_user) do
    with :ok <- validate_provider_response(auth_params),
         auth_params <- prepare_auth_params(auth_params, temp_user) do
      # Use transactional user creation to prevent race conditions
      case TransactionalUserCreation.create_oauth_user_transactionally(
             auth_params,
             profile_params
           ) do
        {:ok, %{user: user, profile: _profile}} ->
          {:ok, user, message} = handle_verification(user, profile_params)
          {:ok, Map.from_struct(user), message}

        {:error, :user_already_exists, reason} ->
          Logger.warning("User already exists during OAuth registration: #{reason}")

          {:error, :user_already_exists,
           "This email is already registered. Please sign in instead."}

        {:error, operation, reason} ->
          Logger.error("Registration failed at #{operation}: #{inspect(reason)}")
          {:error, :registration_failed, format_error_reason(reason)}
      end
    else
      error -> error
    end
  end

  @spec prepare_auth_params(map(), map()) :: map()
  defp prepare_auth_params(
         auth_params,
         %{
           provider: provider,
           email: email,
           verified_email: true
         } = temp_user
       )
       when not is_nil(email) do
    # Convert string keys to ensure consistency
    auth_params
    |> ensure_string_keys()
    |> Map.merge(%{
      "provider" => provider,
      "email" => email,
      "verified_at" => DateTime.utc_now()
    })
    |> add_provider_user_id(temp_user)
  end

  defp prepare_auth_params(auth_params, temp_user) do
    # Convert string keys to ensure consistency
    auth_params
    |> ensure_string_keys()
    |> Map.merge(%{
      "provider" => temp_user.provider,
      "email" => temp_user.email || auth_params["email"],
      "verified_at" => nil
    })
    |> add_provider_user_id(temp_user)
  end

  @spec format_error_reason(any()) :: String.t()
  defp format_error_reason(reason) when is_binary(reason), do: reason

  defp format_error_reason(%Changeset{} = changeset) do
    errors =
      Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Enum.reduce(opts, msg, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", to_string(value))
        end)
      end)

    Enum.map_join(errors, "; ", fn {field, messages} ->
      "#{field}: #{Enum.join(messages, ", ")}"
    end)
  end

  defp format_error_reason(reason), do: inspect(reason)

  @spec handle_verification(Tymeslot.DatabaseSchemas.UserSchema.t() | map(), map()) ::
          {:ok, Tymeslot.DatabaseSchemas.UserSchema.t() | map(), String.t()}
  defp handle_verification(user, _params) do
    if user.verified_at do
      {:ok, user, "Registration completed successfully. Welcome to the dashboard!"}
    else
      {:ok, user, "Verification required. Please check your email."}
    end
  end

  @spec add_provider_user_id(map(), map()) :: map()
  defp add_provider_user_id(auth_params, %{provider: "github", github_user_id: id}),
    do: Map.put(auth_params, "github_user_id", id)

  defp add_provider_user_id(auth_params, %{provider: "google", google_user_id: id}),
    do: Map.put(auth_params, "google_user_id", id)

  defp add_provider_user_id(auth_params, _temp_user), do: auth_params

  @spec ensure_string_keys(map()) :: map()
  defp ensure_string_keys(params) do
    for {k, v} <- params, into: %{}, do: {to_string(k), v}
  end

  @doc """
  Checks if an email is available for registration.
  Returns :ok if available, {:error, reason} otherwise.
  """
  @spec check_email_availability(String.t()) :: :ok | {:error, String.t()}
  def check_email_availability(email) when is_binary(email) do
    case user_queries_module().get_user_by_email(email) do
      {:error, :not_found} ->
        :ok

      {:ok, _user} ->
        Logger.warning("Email already registered: #{email}")
        {:error, "This email is already registered. Please use a different email address."}
    end
  end

  def check_email_availability(other) do
    Logger.warning("Invalid email format: #{inspect(other)}")
    {:error, "Invalid email format"}
  end

  @doc """
  Converts string-keyed map to atom-keyed map (for profile params).
  """
  @spec convert_to_atom_keys(map()) :: map()
  def convert_to_atom_keys(params) do
    for {k, v} <- params, into: %{}, do: {String.to_existing_atom(k), v}
  end

  # Use dependency injection for UserQueries
  # Private validation helper functions

  defp validate_required_fields(params, required_fields) do
    missing_fields =
      Enum.filter(required_fields, fn field ->
        is_nil(params[field]) or params[field] == ""
      end)

    if Enum.empty?(missing_fields) do
      :ok
    else
      {:error, :missing_required_fields, missing_fields}
    end
  end

  defp validate_email_verification(params) do
    case params["verified_email"] do
      true -> :ok
      "true" -> :ok
      _ -> {:error, :email_not_verified}
    end
  end

  defp validate_provider_name(provider) when provider in ["google", "github"], do: :ok
  defp validate_provider_name(_), do: {:error, :invalid_provider}

  defp user_queries_module do
    Tymeslot.DatabaseQueries.UserQueries
  end
end
