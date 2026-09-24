defmodule Tymeslot.Auth.SocialAuthentication do
  @moduledoc """
  Social sign-in rules that sit outside the provider handshake: email
  availability, and completing a registration from the details a provider
  callback left in the session.
  """

  alias Tymeslot.Auth.OAuth.{Providers, UserRegistration}
  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.Config

  require Logger

  @type provider :: Providers.provider()

  # How long the complete-registration form may be left open after the
  # provider callback.
  @pending_ttl_seconds 15 * 60

  @type completion_error ::
          :registration_disabled
          | :missing_pending_registration
          | :unsupported_provider
          | {:provider_disabled, provider()}
          | :registration_expired
          | :email_required
          | :invalid_email
          | :terms_not_accepted
          | :email_already_taken
          | Ecto.Changeset.t()
          | term()

  @doc """
  Completes a social registration from the pending entry the provider
  callback stored and the complete-registration form's `params`.

  Returns `{:ok, provider, user, outcome}` with the account to sign in:
  `:created` for a new one, or `:existing` for the one already carrying this
  provider identity (a form submitted twice signs in the account the first
  submission created). Whether the account gets a session is the caller's
  decision, via its `verified_at`.

  `metadata` is forwarded with the registration broadcast; `terms_accepted`
  is added to it here.
  """
  @spec complete_registration(map() | nil, map(), map()) ::
          {:ok, provider(), map(), :created | :existing} | {:error, completion_error()}
  def complete_registration(pending, params, metadata) do
    with :ok <- check_registration_enabled(),
         {:ok, pending} <- check_pending(pending),
         {:ok, provider} <- Providers.parse(pending[:provider]),
         :ok <- check_provider_enabled(provider),
         :ok <- check_fresh(pending) do
      oauth_data = build_oauth_data(pending, params)

      case UserRegistration.find_existing_user(provider, oauth_data) do
        {:ok, user} -> {:ok, provider, user, :existing}
        {:error, _not_found_or_taken} -> register(provider, oauth_data, params, metadata)
      end
    end
  end

  @doc """
  Checks if an email is available for registration.

  Returns `:ok` if available, `{:error, :email_already_taken}` when an account
  already uses the address, or `{:error, :invalid_email}` for a non-string
  value. The reasons are atoms so that the web layer, not the domain, decides
  how to phrase them in the visitor's locale.
  """
  @spec check_email_availability(term()) :: :ok | {:error, :email_already_taken | :invalid_email}
  def check_email_availability(email) when is_binary(email) do
    case user_queries_module().get_user_by_email(email) do
      {:error, :not_found} ->
        :ok

      {:ok, _user} ->
        Logger.warning("Email already registered")
        {:error, :email_already_taken}
    end
  end

  def check_email_availability(other) do
    Logger.warning("Invalid email format", value: inspect(other))
    {:error, :invalid_email}
  end

  defp register(provider, oauth_data, params, metadata) do
    metadata = Map.put(metadata, :terms_accepted, oauth_data.terms_accepted)

    with :ok <- UserRegistration.validate_completion_data(oauth_data),
         {:ok, user} <-
           UserRegistration.create_oauth_user(provider, oauth_data, profile_params(params),
             metadata: metadata
           ) do
      {:ok, provider, user, :created}
    end
  end

  defp check_registration_enabled do
    if Config.registration_enabled?(), do: :ok, else: {:error, :registration_disabled}
  end

  defp check_pending(pending) when is_map(pending), do: {:ok, pending}
  defp check_pending(_missing), do: {:error, :missing_pending_registration}

  defp check_provider_enabled(provider) do
    if Providers.enabled?(provider), do: :ok, else: {:error, {:provider_disabled, provider}}
  end

  # An entry without `created_at` predates the expiry and is treated as stale.
  defp check_fresh(%{created_at: created_at}) when is_integer(created_at) do
    if DateTime.to_unix(Clock.utc_now()) - created_at <= @pending_ttl_seconds,
      do: :ok,
      else: {:error, :registration_expired}
  end

  defp check_fresh(_pending), do: {:error, :registration_expired}

  # Everything identifying the account comes from the session; only the
  # email (when the provider did not vouch for one) and the terms checkbox
  # come from the form.
  defp build_oauth_data(pending, params) do
    email_from_provider = pending[:email_from_provider] == true

    %{
      provider: pending[:provider],
      email:
        if(email_from_provider, do: pending[:email], else: get_in(params, ["auth", "email"])),
      email_from_provider: email_from_provider,
      provider_uid: pending[:provider_uid],
      name: pending[:name] || "",
      terms_accepted:
        terms_accepted?(get_in(params, ["auth", "terms_accepted"]) || params["terms_accepted"])
    }
  end

  defp profile_params(params), do: %{full_name: get_in(params, ["profile", "full_name"])}

  defp terms_accepted?(value), do: value in [true, "true", "on"]

  defp user_queries_module do
    Config.user_queries_module()
  end
end
