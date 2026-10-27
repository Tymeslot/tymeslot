defmodule Tymeslot.Auth.EmailChange do
  @moduledoc """
  Handles email change requests, verification, and cancellation.

  Orchestrates the multi-step email change flow: validating the request,
  persisting tokens, scheduling notification emails, and confirming the
  change via a verification link.

  A request is a form submission and fails with `{:error, %{field =>
  message}}`, so every field's problem can be shown at once. Verifying and
  cancelling fail with `{:error, {reason, message}}`: `reason` is an atom a
  caller can branch on, `message` is translated and ready to show.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Ecto.Changeset

  alias Tymeslot.Auth.{
    AccountTokens,
    ErrorFormatter,
    RateLimit,
    Session,
    UserQueries,
    UserTokenQueries,
    Validation
  }

  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Repo
  alias Tymeslot.Security.{InputProcessor, RateLimiter, Token}
  alias Tymeslot.Utils.UrlBuilder

  require Logger

  @type error :: {:error, {atom(), String.t()}}

  @doc """
  Requests an email change for a user.
  Validates password, creates token, stores pending email, and sends verification emails.

  A failure is `{:error, %{field => message}}`, keyed by the form field each
  message belongs to (`:current_password`, `:new_email`). Malformed input is
  reported for every field at once, before the password is checked. Emails
  that cannot be queued are reported against `:new_email`; the change stays
  pending, unconfirmable without its link, and lapses or is replaced by the
  next request.

  `user` only identifies the account: it is re-read under a row lock, so the
  password is checked against the current hash and the request serialises
  with a concurrent password change instead of slipping a token in after it.

  `opts` carries the request context (`:ip`, `:user_agent`). The request is
  held to the login rate limit, since it checks a password; over it the
  result is `{:error, :rate_limited, message}` and nothing is checked.

  An address that already belongs to an account (the requester's own
  included) is answered exactly as a free one, so the form cannot be used to
  learn which addresses are registered. The change is recorded as pending, as
  for a free address, so the pending notice, cancelling and expiry look the
  same, and the current address is told of it as usual; but its token is
  thrown away rather than mailed, so it can never be confirmed, and it lapses
  like any unconfirmed change. When another account
  holds the address as its own live pending change, the change cannot be
  recorded at all; the answer is still the same, but nothing is pending.
  """
  @spec request_email_change(term(), term(), term(), keyword()) ::
          {:ok, term(), String.t()}
          | {:error, %{optional(:current_password | :new_email) => String.t()}}
          | {:error, :rate_limited, String.t()}
  def request_email_change(user, new_email, current_password, opts \\ []) do
    RateLimit.with_limit(
      RateLimiter.check_auth_rate_limit(user.email, opts[:ip]),
      [
        event: "email_change",
        identifier: user.email,
        ip: opts[:ip],
        user_agent: opts[:user_agent]
      ],
      fn -> do_request_email_change(user, new_email, current_password) end
    )
  end

  defp do_request_email_change(user, new_email, current_password) do
    with {:ok, new_email} <- validate_input(new_email, current_password),
         {:ok, updated_user, delivery} <-
           issue_in_transaction(user.id, new_email, current_password),
         :ok <- deliver(delivery, updated_user, new_email) do
      {:ok, updated_user, request_sent_message(new_email)}
    else
      {:error, :pending_elsewhere} ->
        {:ok, user, request_sent_message(new_email)}

      {:error, errors} when is_map(errors) and not is_struct(errors) ->
        {:error, errors}

      {:error, reason} when reason in [:invalid_password, :missing_password] ->
        {:error, %{current_password: Validation.current_password_message(reason)}}

      {:error, :not_found} ->
        {:error, %{current_password: Validation.current_password_message(:invalid_password)}}

      {:error, %Changeset{} = changeset} ->
        {:error, %{new_email: format_changeset_error(changeset)}}

      # The change is recorded but its emails could not be queued. Saying the
      # link was sent would leave the user waiting on an email that is never
      # coming; asking again issues a fresh link, and the unsent one lapses.
      {:error, :not_sent} ->
        {:error,
         %{
           new_email:
             dgettext("auth", "The verification email could not be sent. Please try again.")
         }}
    end
  end

  # Both branches answer a failure the same way, so a taken address still
  # cannot be told from a free one.
  defp deliver({:send, token}, user, new_email) do
    user.id
    |> EmailScheduler.schedule_email_change_emails(
      new_email,
      UrlBuilder.email_change_url(token),
      Token.hash_token(token)
    )
    |> sent()
  end

  # The current address hears of the change either way, as it would for a
  # free address; only the link is withheld.
  defp deliver(:withhold, user, new_email) do
    user.id
    |> EmailScheduler.schedule_email_change_notification(new_email)
    |> sent()
  end

  defp sent(:ok), do: :ok
  defp sent({:error, _reason}), do: {:error, :not_sent}

  defp request_sent_message(new_email),
    do: dgettext("auth", "Verification email sent to %{email}", email: new_email)

  # Every field's problem at once, so the form can show them together. The
  # current password is held only to login's presence and length rules.
  defp validate_input(new_email, current_password) do
    email_result =
      InputProcessor.validate_field(new_email, :email, universal_opts: [allow_html: false])

    errors =
      Enum.reduce(
        [email_result, Validation.validate_current_password_input(current_password)],
        %{},
        fn
          {:error, message}, acc when is_binary(message) ->
            Map.put(acc, :new_email, message)

          {:error, reason}, acc when is_atom(reason) ->
            Map.put(acc, :current_password, Validation.current_password_message(reason))

          _ok, acc ->
            acc
        end
      )

    case {errors, email_result} do
      {empty, {:ok, sanitised_email}} when empty == %{} -> {:ok, sanitised_email}
      {errors, _email_result} -> {:error, errors}
    end
  end

  defp issue_in_transaction(user_id, new_email, current_password) do
    result =
      Repo.transaction(fn ->
        # An expired change elsewhere must not hold the address. Released
        # before the requester's row is read, so their own expired change to
        # the same address is not left stale in the struct being updated.
        _released = AccountTokens.release_expired_email_changes(pending_email: new_email)

        with {:ok, user} <- UserQueries.get_user_for_update(user_id),
             :ok <- Validation.check_current_password(user, current_password),
             registered? = UserQueries.email_registered?(new_email),
             {:ok, updated_user, token} <-
               AccountTokens.issue(:email_change, user, %{new_email: new_email}) do
          # A registered address keeps its pending row but never gets the
          # token, which nobody else holds, so the change cannot be confirmed.
          {updated_user, if(registered?, do: :withhold, else: {:send, token})}
        else
          {:error, %Changeset{} = changeset} ->
            if pending_elsewhere?(changeset),
              do: Repo.rollback(:pending_elsewhere),
              else: Repo.rollback(changeset)

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, {updated_user, delivery}} -> {:ok, updated_user, delivery}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Verifies and completes an email change using the verification token.
  Uses a database transaction to ensure atomicity.

  A failure's reason is `:rate_limited`, `:invalid_token`, `:token_expired`
  or `:changeset_error`. `opts` carries the request context (`:ip`,
  `:user_agent`), which keys the per-address limit on following links.
  """
  @spec verify_email_change(String.t(), keyword()) ::
          {:ok, Ecto.Schema.t(), String.t()} | error()
  def verify_email_change(token, opts \\ []) when is_binary(token) do
    limit = RateLimiter.check(:email_change_verify, opts[:ip])
    context = [event: "email_change_verify", ip: opts[:ip], user_agent: opts[:user_agent]]

    case RateLimit.check(limit, context) do
      :ok -> complete_email_change(token)
      {:error, :rate_limited, message} -> {:error, {:rate_limited, message}}
    end
  end

  defp complete_email_change(token) do
    case verify_email_change_in_transaction(token) do
      {:ok, result} ->
        # After successful commit, disconnect any live sockets bound to the
        # now-revoked sessions, then enqueue confirmation emails.
        Session.disconnect_sessions(result.revoked_session_hashes)

        _result =
          EmailScheduler.schedule_email_change_confirmations(
            result.user.id,
            result.old_email,
            result.user.email
          )

        {:ok, result.user,
         dgettext("auth", "Email changed successfully. Please sign in with your new email.")}

      {:error, :invalid_token} ->
        {:error, {:invalid_token, dgettext("auth", "Invalid or expired verification link")}}

      {:error, {:token_expired, user_id}} ->
        # The transaction rolled back, so the expired change is released here.
        _released = AccountTokens.release_expired_email_changes(user_id: user_id)
        {:error, {:token_expired, dgettext("auth", "Verification link has expired")}}

      {:error, %Changeset{} = changeset} ->
        {:error, {:changeset_error, flashed_changeset_error(changeset)}}
    end
  end

  @doc """
  Cancels a pending email change request. A failure's reason is
  `:changeset_error`.
  """
  @spec cancel_email_change(Ecto.Schema.t()) :: {:ok, Ecto.Schema.t(), String.t()} | error()
  def cancel_email_change(user) do
    case UserTokenQueries.cancel_email_change(user) do
      {:ok, updated_user} ->
        Logger.info("Email change cancelled", user_id: updated_user.id)
        {:ok, updated_user, dgettext("auth", "Email change request cancelled")}

      {:error, %Changeset{} = changeset} ->
        {:error, {:changeset_error, flashed_changeset_error(changeset)}}
    end
  end

  # --- Private helpers ---

  # The token row is locked for the length of the transaction, so two clicks
  # on the same link cannot both apply the change.
  defp verify_email_change_in_transaction(token) do
    Repo.transaction(fn ->
      with {:ok, user} <- AccountTokens.fetch(:email_change, token, lock: true),
           {:ok, updated_user} <- AccountTokens.consume(:email_change, user) do
        # Invalidate all existing sessions for security. The caller
        # disconnects their live sockets only after this transaction commits.
        revoked_session_hashes = Session.delete_session_rows(updated_user.id)

        Logger.info("Email change verified successfully", user_id: updated_user.id)

        %{
          user: updated_user,
          old_email: user.email,
          revoked_session_hashes: revoked_session_hashes
        }
      else
        {:error, :token_expired, user} -> Repo.rollback({:token_expired, user.id})
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # Another account's live pending change holds the address: caught by the
  # changeset's pre-check, or by the unique index when a concurrent request
  # wins the race.
  defp pending_elsewhere?(%Changeset{errors: errors}) do
    case Keyword.get(errors, :pending_email) do
      {_message, opts} -> opts[:constraint] == :unique or opts[:validation] == :unsafe_unique
      nil -> false
    end
  end

  # Shown under the new-address field, so the message stands alone.
  defp format_changeset_error(%Changeset{} = changeset) do
    ErrorFormatter.first_error(changeset)
  end

  # Verifying or cancelling answers with a flash, away from any field.
  defp flashed_changeset_error(%Changeset{} = changeset) do
    address = dgettext("auth", "Email address")
    ErrorFormatter.first_error(changeset, %{email: address, pending_email: address})
  end
end
