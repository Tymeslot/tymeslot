defmodule Tymeslot.Integrations.Shared.ReauthHandling do
  @moduledoc """
  Shared handler for the paths that end in "the user has to reconnect".

  The original caller was the "credentials no longer decrypt" path: when a
  query module returns `{:error, :requires_reencryption, integration}`, callers
  delegate here to log a warning, flag the integration for reauthentication,
  and return a normalised result. Permanent OAuth failures (an expired or
  revoked grant, credentials the provider now rejects) share the same
  side-effects but not the same diagnosis, so the reason is carried explicitly
  as a `t:cause/0`.

  Two distinct return shapes are available depending on context:

  - `flag/2` — returns `:ok | {:error, changeset}`. Suitable for non-Oban
    callers (fetch helpers, token refreshers) that just want the side-effect
    and a simple success/failure signal.

  - Oban workers that need `{:discard, _} | {:error, _}` build that shape
    themselves on top of `flag/2`, typically via the
    `CalendarManagement.handle_reauth_required/2` or
    `Video.handle_reauth_required/2` wrappers.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  @typedoc """
  Why the integration needs reconnecting.

  * `:credentials_undecryptable` — the stored ciphertext no longer decrypts
    under the current encryption key.
  * `:expired_grant` — the OAuth grant has expired or the user revoked it.
  * `:rejected_credentials` — the provider rejected the credentials for some
    other permanent reason (`invalid_client`, `access_denied`, a bare 401).
  """
  @type cause :: :credentials_undecryptable | :expired_grant | :rejected_credentials

  @default_cause :credentials_undecryptable

  # One row per cause: the operator-facing log line and the message persisted
  # to the integration's `sync_error`, which the account owner reads. Keeping
  # them together stops the two from drifting, and stops a decryption
  # diagnosis being reused for an OAuth failure it does not describe. Only
  # `message` is translated — `log` stays English so operator-facing logs read
  # the same whatever locale the flagging process happens to carry.
  @causes %{
    credentials_undecryptable: %{
      log: "Integration credentials cannot be decrypted — flagging for reauth",
      message:
        dgettext_noop(
          "dashboard_integrations",
          "Stored credentials could not be decrypted with the current encryption key. Please reconnect the integration."
        )
    },
    expired_grant: %{
      log: "Integration authorisation has expired or been revoked — flagging for reauth",
      message:
        dgettext_noop(
          "dashboard_integrations",
          "Access to the connected account has expired or been revoked. Please reconnect the integration."
        )
    },
    rejected_credentials: %{
      log: "Integration credentials were rejected by the provider — flagging for reauth",
      message:
        dgettext_noop(
          "dashboard_integrations",
          "The provider rejected the stored credentials for this integration. Please reconnect the integration."
        )
    }
  }

  @doc """
  The error message recorded when flagging an integration for reauth.

  Exposed so callers that build their own Oban return shapes can embed it.
  Defaults to the decryption cause, which is the path this module was built
  for; pass a `t:cause/0` for the others.
  """
  @spec reauth_error_message(cause()) :: String.t()
  def reauth_error_message(cause \\ @default_cause),
    do: translate_message(fetch_cause(cause).message)

  @doc """
  Flags an integration for reauthentication.

  Options (keyword list):

  - `:mark_needs_reauth` — a `(integration, message) -> {:ok, _} | {:error, changeset}`
    function that persists the flag. **Required.**
  - `:cause` — a `t:cause/0` selecting the diagnosis logged and persisted.
    Defaults to `:credentials_undecryptable`.
  - `:provider_label` — a function extracting the provider string from the
    integration, e.g. `& &1.provider`. Defaults to `& &1.provider`.
  - `:log_prefix` — a short label used in log messages, e.g. `"Calendar"` or
    `"Video"`. Defaults to `"Integration"`.

  Logs a warning, calls `mark_needs_reauth`, then:

  - Returns `:ok` on `{:ok, _}`.
  - Logs an error and returns `{:error, changeset}` on `{:error, changeset}`.
  """
  @spec flag(struct(), keyword()) :: :ok | {:error, Ecto.Changeset.t()}
  def flag(integration, opts) do
    mark_needs_reauth = Keyword.fetch!(opts, :mark_needs_reauth)
    provider_label_fun = Keyword.get(opts, :provider_label, & &1.provider)
    log_prefix = Keyword.get(opts, :log_prefix, "Integration")
    cause = fetch_cause(Keyword.get(opts, :cause, @default_cause))

    provider = provider_label_fun.(integration)

    Logger.warning(
      cause.log,
      integration_type: log_prefix,
      provider: provider,
      integration_id: integration.id,
      user_id: integration.user_id
    )

    case mark_needs_reauth.(integration, translate_message(cause.message)) do
      {:ok, _integration} ->
        :ok

      {:error, changeset} ->
        Logger.error(
          "Failed to persist needs_reauth flag",
          provider: provider,
          integration_id: integration.id,
          errors: inspect(changeset.errors)
        )

        {:error, changeset}
    end
  end

  defp fetch_cause(cause), do: Map.get(@causes, cause) || @causes[@default_cause]

  defp translate_message(msgid),
    do: Gettext.dgettext(TymeslotWeb.Gettext, "dashboard_integrations", msgid)
end
