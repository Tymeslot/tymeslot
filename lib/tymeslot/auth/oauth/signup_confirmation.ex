defmodule Tymeslot.Auth.OAuth.SignupConfirmation do
  @moduledoc """
  Social sign-up with an address the user typed, finished only once they
  prove they own it.

  When the provider vouches for no email, the complete-registration form asks
  for one. Creating the account there and then (unverified) would make the
  address's fate visible: a free address gains an account linked to the
  identity, so the next sign-in with that identity lands somewhere different
  from a taken address's. So no account is created at the form. Instead the
  typed address is emailed a link carrying a signed, expiring token holding
  everything the account needs; following it creates the account, already
  verified, and signs the owner in. A taken address is sent the sign-up
  attempt notice instead. The form's reply is identical either way, and until
  the link is followed the identity stays unlinked in both cases.

  The token is signed, not encrypted, so it carries nothing that is not also
  in the email it travels in. It is kept out of the session and, like every
  emailed link, stored encrypted in the job's args.
  """

  require Logger

  alias Phoenix.Token
  alias Tymeslot.Auth.OAuth.{Providers, UserRegistration}
  alias Tymeslot.Auth.UserQueries
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Repo
  alias Tymeslot.Security.{RateLimiter, SecurityLogger}
  alias Tymeslot.Utils.UrlBuilder
  alias TymeslotWeb.Endpoint

  @salt "oauth typed-email sign-up confirmation"
  @max_age_seconds 24 * 60 * 60

  @type provider :: Providers.provider()

  @doc """
  Emails `oauth_data.email` the link that finishes this sign-up.

  Spends the requesting address's verification allowance first, exactly as a
  sign-up with a taken address does (`Registration.answer_taken_address/2`),
  and reports the same `:sent` or `:rate_limited`. Over the recipient's own
  cap nothing is sent, and the reply does not change.
  """
  @spec request(provider(), map(), map(), String.t() | nil) :: :sent | :rate_limited
  def request(provider, oauth_data, profile_params, ip) do
    case RateLimiter.check_verification_ip_rate_limit(ip) do
      :ok ->
        send_link(provider, oauth_data, profile_params)
        :sent

      {:error, :rate_limited, _message} ->
        :rate_limited
    end
  end

  defp send_link(provider, oauth_data, profile_params) do
    email = oauth_data.email

    with :ok <- RateLimiter.check_social_signup_confirmation_rate_limit(email),
         {:ok, _status} <-
           EmailScheduler.schedule_social_signup_confirmation(%{
             email: email,
             name: oauth_data[:name],
             provider: to_string(provider),
             confirm_url: confirm_url(sign(provider, oauth_data, profile_params)),
             locale: Gettext.get_locale(TymeslotWeb.Gettext)
           }) do
      :ok
    else
      {:error, :rate_limited, _message} ->
        SecurityLogger.log_rate_limit_violation(email, "social_signup_confirmation", %{})

      {:error, reason} ->
        Logger.error("Failed to schedule sign-up confirmation", reason: inspect(reason))
    end
  end

  defp confirm_url(token), do: UrlBuilder.build_url("/auth/oauth/confirm/#{token}")

  defp sign(provider, oauth_data, profile_params) do
    Token.sign(Endpoint, @salt, %{
      "provider" => to_string(provider),
      "provider_uid" => oauth_data.provider_uid,
      "email" => oauth_data.email,
      "name" => oauth_data[:name],
      "terms_accepted" => oauth_data[:terms_accepted] == true,
      "full_name" => profile_params[:full_name]
    })
  end

  @doc """
  Finishes the sign-up `token` describes: creates the account, verified, and
  returns it for signing in.

  Any reason not to (expired, tampered, the identity already linked, the
  address taken since, sign-ups or the provider switched off) is the one
  `{:error, :invalid_link}`: the visitor is sent to sign in either way, and
  the reason is logged, not shown.
  """
  @spec confirm(String.t(), map()) :: {:ok, provider(), map()} | {:error, :invalid_link}
  def confirm(token, metadata) when is_binary(token) do
    with {:ok, claims} <- verify(token),
         {:ok, provider} <- Providers.parse(claims["provider"]),
         :ok <- still_possible(provider, claims),
         {:ok, user} <- create(provider, claims, metadata) do
      {:ok, provider, user}
    else
      reason ->
        Logger.info("Sign-up confirmation link refused", reason: inspect(reason))
        {:error, :invalid_link}
    end
  end

  def confirm(_token, _metadata), do: {:error, :invalid_link}

  defp verify(token),
    do: Token.verify(Endpoint, @salt, token, max_age: @max_age_seconds)

  defp still_possible(provider, claims) do
    cond do
      not Config.registration_enabled?() ->
        :registration_disabled

      not Providers.enabled?(provider) ->
        :provider_disabled

      Providers.find_user(provider, claims["provider_uid"], Repo) != {:error, :not_found} ->
        :identity_linked

      match?({:ok, _user}, UserQueries.get_user_by_email(claims["email"])) ->
        :email_taken

      true ->
        :ok
    end
  end

  # The address is proved by the click, so the account is created exactly as
  # one whose email the provider vouched for: verified.
  defp create(provider, claims, metadata) do
    oauth_data = %{
      provider: claims["provider"],
      provider_uid: claims["provider_uid"],
      email: claims["email"],
      email_from_provider: true,
      name: claims["name"] || "",
      terms_accepted: claims["terms_accepted"]
    }

    case UserRegistration.create_oauth_user(
           provider,
           oauth_data,
           %{full_name: claims["full_name"]},
           metadata: Map.put(metadata, :terms_accepted, claims["terms_accepted"])
         ) do
      {:ok, %{verified_at: %DateTime{}} = user} -> {:ok, user}
      other -> {:not_created, other}
    end
  end
end
