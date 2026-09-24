defmodule Tymeslot.Auth.SocialAuthentication do
  @moduledoc """
  Social sign-in decisions: what a provider callback means for the visitor
  (sign in, verify first, register, or refuse), completing a registration
  from the details that callback left behind, and the audit trail and rate
  limits every social entry point shares.

  Carrying the flow on the connection (the OAuth state and PKCE verifier,
  the session cookie) is the web layer's job, in `TymeslotWeb.OAuthFlow`.
  Every function here takes the client's `:ip` and `:user_agent` as options.
  """

  require Logger

  alias Tymeslot.Auth.OAuth.{
    Client,
    Providers,
    SignupConfirmation,
    UserProcessor,
    UserRegistration
  }

  alias Tymeslot.Auth.{RateLimit, Registration, Validation, Verification}
  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Security.{RateLimiter, SecurityLogger}

  @type provider :: Providers.provider()

  # How long the complete-registration form may be left open after the
  # provider callback.
  @pending_ttl_seconds 15 * 60

  @type delivery :: :sent | :rate_limited | :failed

  @type admission :: {:sign_in, map()} | {:verify, map(), delivery()}

  @type callback_outcome ::
          admission()
          | {:register, map()}
          | {:error,
             :oauth_error | :general_error | :registration_disabled | :email_already_taken}

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
  The provider's authorise URL for a new sign-in, carrying the flow's
  `state` and PKCE `code_challenge`.
  """
  @spec authorize_url(provider(), String.t(), %{state: String.t(), code_challenge: String.t()}) ::
          String.t()
  defdelegate authorize_url(provider, callback_url, flow), to: Client

  @doc """
  Decides what a provider callback means, once the web layer has checked the
  flow's state and recovered its PKCE `code_verifier`.

  Exchanges the code, fetches the identity and finds the account it belongs
  to (by the provider's own user ID, never by email). Returns:

    * `{:sign_in, user}` - a verified account; start a session
    * `{:verify, user, delivery}` - an account whose email is unverified; no
      session, and it has been resent its verification link (see `admit/3`)
    * `{:register, pending}` - a new identity; `pending` is what the
      complete-registration form needs, to be kept until it is submitted
    * `{:error, :oauth_error}` - the provider refused the code or its token
    * `{:error, :general_error}` - the provider was unreachable or its answer
      unusable
    * `{:error, :email_already_taken}` - no account carries this identity,
      but its email belongs to one created another way
    * `{:error, :registration_disabled}` - a new identity, and sign-ups are
      closed

  Every refusal is audited.
  """
  @spec resolve_callback(provider(), String.t(), String.t(), String.t(), keyword()) ::
          callback_outcome()
  def resolve_callback(provider, code, code_verifier, callback_url, opts) do
    with {:ok, identity} <- fetch_identity(provider, code, code_verifier, callback_url, opts) do
      case UserRegistration.find_existing_user(provider, identity) do
        {:ok, existing} ->
          existing
          |> UserRegistration.verify_vouched_email(identity)
          |> admit(provider, opts)

        {:error, :not_found} ->
          new_identity(provider, identity, opts)

        {:error, :email_already_taken} ->
          refuse(provider, identity, :email_already_taken, opts)
      end
    end
  end

  @doc """
  Decides whether the account a social sign-in resolved to may have a
  session: `{:sign_in, user}` when its email is verified.

  An unverified account gets `{:verify, user, delivery}` instead: it is
  resent its verification link, within the usual limits, and `delivery` says
  whether the email went out (`:sent`), was refused by the rate limiter
  (`:rate_limited`) or failed (`:failed`).
  """
  @spec admit(map(), provider(), keyword()) :: admission()
  def admit(%{verified_at: nil} = user, provider, opts) do
    delivery =
      case Verification.send_verification_email(user, opts[:ip]) do
        {:ok, _user} -> :sent
        {:error, :rate_limited, _message} -> :rate_limited
        {:error, _reason} -> :failed
      end

    audit(
      provider,
      false,
      %{email: Map.get(user, :email), error_reason: "email_not_verified"},
      opts
    )

    {:verify, user, delivery}
  end

  def admit(user, _provider, _opts), do: {:sign_in, user}

  @doc """
  Records a social-auth audit entry via `SecurityLogger.log_social_auth_event/3`.

  Shared by every social entry point so the audit shape stays in one place.
  No email is available in the state-check and early-error branches; the
  masking helper drops a nil address cleanly. The OAuth code, state and
  client tokens are never recorded.
  """
  @spec audit(provider() | String.t() | nil, boolean(), map(), keyword()) :: :ok
  def audit(provider, success, details, opts) do
    SecurityLogger.log_social_auth_event(
      to_string(provider),
      success,
      Map.merge(%{ip_address: opts[:ip], user_agent: opts[:user_agent]}, details)
    )
  end

  @doc """
  Charges the per-address limit on a social entry point: starting a sign-in
  (`:initiation`), handling the provider's callback (`:callback`), or
  completing a sign-up (`:completion`). A refusal is audited.
  """
  @spec check_rate_limit(:initiation | :callback | :completion, keyword()) ::
          :ok | {:error, :rate_limited, String.t()}
  def check_rate_limit(action, opts) do
    ip = opts[:ip]

    RateLimit.check(oauth_limit(action, ip),
      event: "oauth_#{action}",
      identifier: ip,
      ip: ip,
      user_agent: opts[:user_agent]
    )
  end

  defp oauth_limit(:initiation, ip), do: RateLimiter.check_oauth_initiation_rate_limit(ip)
  defp oauth_limit(:callback, ip), do: RateLimiter.check_oauth_callback_rate_limit(ip)
  defp oauth_limit(:completion, ip), do: RateLimiter.check_oauth_completion_rate_limit(ip)

  @doc """
  Finishes a social sign-up from its emailed confirmation link: creates the
  account, verified, and returns it for signing in; see
  `Tymeslot.Auth.OAuth.SignupConfirmation.confirm/2`. `opts` carries the
  client, recorded on the registration broadcast.
  """
  @spec confirm_signup(String.t(), keyword()) ::
          {:ok, provider(), map()} | {:error, :invalid_link}
  def confirm_signup(token, opts), do: SignupConfirmation.confirm(token, signup_metadata(opts))

  # The registration broadcast's metadata for a social sign-up by the client
  # in `opts`. `terms_accepted` is added where the account is created.
  defp signup_metadata(opts),
    do: %{ip: opts[:ip], user_agent: opts[:user_agent], source: "oauth_signup"}

  defp fetch_identity(provider, code, code_verifier, callback_url, opts) do
    with {:ok, token} <- Client.exchange_code(provider, code, code_verifier, callback_url),
         {:ok, identity} <- UserProcessor.fetch_identity(provider, token) do
      {:ok, identity}
    else
      {:error, reason} ->
        error =
          if match?({:provider_rejected, _status}, reason), do: :oauth_error, else: :general_error

        Logger.error("OAuth authentication error",
          provider: to_string(provider),
          reason: inspect(reason)
        )

        audit(provider, false, %{error_reason: Atom.to_string(error)}, opts)
        {:error, error}
    end
  end

  # A new identity always goes through the complete-registration form, even
  # with every field known: the account is created on explicit confirmation,
  # never silently.
  defp new_identity(provider, identity, opts) do
    case check_registration_enabled() do
      :ok -> {:register, pending_registration(provider, identity)}
      {:error, reason} -> refuse(provider, identity, reason, opts)
    end
  end

  defp refuse(provider, identity, reason, opts) do
    audit(
      provider,
      false,
      %{email: Map.get(identity, :email), error_reason: to_string(reason)},
      opts
    )

    {:error, reason}
  end

  # Kept by the web layer until the complete-registration form is submitted.
  # `created_at` (unix seconds) lets the completion refuse a stale entry.
  defp pending_registration(provider, identity) do
    %{
      provider: to_string(provider),
      email: identity.email || "",
      name: identity.name || "",
      email_from_provider: identity.email_from_provider == true,
      provider_uid: identity.provider_uid,
      created_at: DateTime.to_unix(Clock.utc_now())
    }
  end

  @doc """
  Completes a social registration from the pending entry the provider
  callback stored and the complete-registration form's `params`.

  Returns `{:ok, provider, user, outcome}` with the account to sign in:
  `:created` for a new one, or `:existing` for the one already carrying this
  provider identity (a form submitted twice signs in the account the first
  submission created). Whether the account gets a session is the caller's
  decision, via its `verified_at`.

  Returns `{:ok, provider, :check_email, delivery}` for an address typed into
  the form, taken or free: no account is created either way. A free address
  is emailed a link that finishes the sign-up; a taken one's owner is sent
  the sign-up attempt notice. The caller must answer both identically, using
  `delivery` (`:sent` or `:rate_limited`) only to say whether an email went
  out.

  `opts` carries the client (`:ip`, `:user_agent`); a created account's
  registration broadcast records it, with the source and whether the terms
  were accepted.
  """
  @spec complete_registration(map() | nil, map(), keyword()) ::
          {:ok, provider(), map(), :created | :existing}
          | {:ok, provider(), :check_email, :sent | :rate_limited}
          | {:error, completion_error()}
  def complete_registration(pending, params, opts) do
    metadata = signup_metadata(opts)

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

  defp register(provider, oauth_data, params, metadata) do
    metadata = Map.put(metadata, :terms_accepted, oauth_data.terms_accepted)

    with :ok <- UserRegistration.validate_completion_data(oauth_data) do
      case taken_account(oauth_data) do
        {:typed, existing} ->
          {:ok, provider, :check_email,
           Registration.answer_taken_address(existing, metadata[:ip])}

        :typed_free ->
          {:ok, provider, :check_email,
           SignupConfirmation.request(provider, oauth_data, profile_params(params), metadata[:ip])}

        {:vouched, _existing} ->
          {:error, :email_already_taken}

        :vouched_free ->
          create(provider, oauth_data, params, metadata)
      end
    end
  end

  # An address typed into the form could be anyone's, so nothing is created
  # for it here: a free one is emailed a link that finishes the sign-up (see
  # `Tymeslot.Auth.OAuth.SignupConfirmation`), a taken one's owner is sent the
  # sign-up attempt notice, and the reply is the same. One the provider
  # vouched for belongs to whoever signed in with it, so its account is
  # created at once, and saying it is taken tells them nothing new.
  defp taken_account(%{email: email, email_from_provider: from_provider}) do
    case {user_queries_module().get_user_by_email(email), from_provider} do
      {{:ok, existing}, true} -> {:vouched, existing}
      {{:ok, existing}, false} -> {:typed, existing}
      {{:error, :not_found}, true} -> :vouched_free
      {{:error, :not_found}, false} -> :typed_free
    end
  end

  defp create(provider, oauth_data, params, metadata) do
    with {:ok, user} <-
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
        Validation.terms_accepted?(
          get_in(params, ["auth", "terms_accepted"]) || params["terms_accepted"]
        )
    }
  end

  defp profile_params(params), do: %{full_name: get_in(params, ["profile", "full_name"])}

  defp user_queries_module do
    Config.user_queries_module()
  end
end
