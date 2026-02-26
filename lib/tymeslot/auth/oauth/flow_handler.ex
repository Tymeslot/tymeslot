defmodule Tymeslot.Auth.OAuth.FlowHandler do
  @moduledoc """
  Orchestrates the OAuth flow, typically called from controllers.
  """

  require Logger
  alias Phoenix.Controller
  alias Tymeslot.Auth.OAuth.{Client, State, URLs, UserProcessor, UserRegistration}
  alias Tymeslot.Auth.Session

  @type provider :: :github | :google

  @doc """
  Handles the complete OAuth callback flow.
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

  # Private helpers

  defp validate_oauth_state(conn, state, context) do
    case State.validate_state(conn, state) do
      :ok ->
        State.clear_oauth_state(conn)

      {:error, :invalid_state} ->
        {:error, handle_invalid_state(conn, context.login_path)}
    end
  end

  defp process_oauth_response({:error, conn}, _context), do: {:error, conn}

  defp process_oauth_response(conn, %{code: code, provider: provider} = context) do
    full_callback_url = URLs.callback_url(conn, URLs.callback_path(provider))
    client = Client.build(provider, full_callback_url, "")

    with {:ok, client} <- Client.exchange_code_for_token(client, code),
         {:ok, user_info} <- Client.get_user_info(client, provider),
         {:ok, user} <- UserProcessor.process_user(provider, user_info),
         enhanced_user <- UserProcessor.enhance_user_data(provider, user, client) do
      {conn, enhanced_user}
    else
      {:error, %OAuth2.Error{} = error} ->
        {:error, handle_oauth_error(conn, provider, error, context.login_path)}

      {:error, reason} ->
        {:error, handle_general_error(conn, provider, reason, context.login_path)}
    end
  end

  defp complete_oauth_flow({:error, conn}, _context), do: conn

  defp complete_oauth_flow({conn, user}, context) do
    case UserRegistration.find_existing_user(context.provider, user) do
      {:ok, existing_user} ->
        create_user_session(conn, existing_user, context)

      {:error, :not_found} ->
        handle_new_user_registration(conn, context.provider, user, context.registration_path)
    end
  end

  defp create_user_session(conn, user, context) do
    case Session.create_session(conn, %{id: user.id}) do
      {:ok, conn, _token} ->
        conn
        |> Controller.put_flash(
          :info,
          "Successfully signed in with #{provider_name(context.provider)}."
        )
        |> Controller.redirect(to: context.success_path)

      {:error, reason, _message} ->
        Logger.error("Failed to create session after OAuth auth",
          provider: context.provider,
          reason: inspect(reason)
        )

        conn
        |> Controller.put_flash(:error, "Authentication succeeded but session creation failed.")
        |> Controller.redirect(to: context.login_path)
    end
  end

  defp handle_new_user_registration(conn, provider, user, registration_path) do
    case UserRegistration.check_oauth_requirements(provider, user) do
      {:missing, missing_fields} ->
        params = build_modal_params(provider, user, missing_fields)
        query_params = URI.encode_query(params)
        Controller.redirect(conn, to: "#{registration_path}?#{query_params}")

      :complete ->
        # This case should ideally not happen if requirements are checked correctly
        # but we handle it for robustness.
        Controller.redirect(conn, to: "/")
    end
  end

  defp build_modal_params(provider, user, missing_fields) do
    base_params = %{
      "auth" => "oauth_complete",
      "oauth_provider" => to_string(provider),
      "oauth_missing" => Enum.join(missing_fields, ",")
    }

    email_from_provider = user.email != nil and String.trim(user.email) != ""

    oauth_data = %{
      "oauth_email" => user.email || "",
      "oauth_verified" => to_string(user.is_verified),
      "oauth_email_from_provider" => to_string(email_from_provider),
      "oauth_#{provider}_id" => Map.get(user, String.to_existing_atom("#{provider}_user_id")),
      "oauth_name" => user.name || ""
    }

    Map.merge(base_params, oauth_data)
  end

  defp handle_invalid_state(conn, login_path) do
    Logger.warning("OAuth callback received with invalid or missing state parameter")

    conn
    |> Controller.put_flash(:error, "Security validation failed. Please try again.")
    |> Controller.redirect(to: login_path)
  end

  defp handle_oauth_error(conn, provider, error, login_path) do
    Logger.error("OAuth error", provider: provider_name(provider), error: inspect(error))

    conn
    |> Controller.put_flash(:error, "Failed to authenticate with #{provider_name(provider)}.")
    |> Controller.redirect(to: login_path)
  end

  defp handle_general_error(conn, provider, reason, login_path) do
    Logger.error("OAuth authentication error",
      provider: provider_name(provider),
      reason: inspect(reason)
    )

    conn
    |> Controller.put_flash(
      :error,
      "An error occurred during #{provider_name(provider)} authentication."
    )
    |> Controller.redirect(to: login_path)
  end

  defp provider_name(:github), do: "GitHub"
  defp provider_name(:google), do: "Google"
end
