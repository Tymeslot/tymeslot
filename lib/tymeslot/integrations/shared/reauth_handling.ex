defmodule Tymeslot.Integrations.Shared.ReauthHandling do
  @moduledoc """
  Shared handler for the "credentials no longer decrypt" path.

  When a query module returns `{:error, :requires_reencryption, integration}`,
  callers delegate to this module to log a warning, flag the integration for
  reauthentication, and return a normalised result.

  Two distinct return shapes are available depending on context:

  - `flag/2` — returns `:ok | {:error, changeset}`. Suitable for non-Oban
    callers (fetch helpers, token refreshers) that just want the side-effect
    and a simple success/failure signal.

  - Oban workers that need `{:discard, _} | {:error, _}` build that shape
    themselves on top of `flag/2`, typically via the
    `CalendarManagement.handle_reauth_required/1` or
    `Video.handle_reauth_required/1` wrappers.
  """

  require Logger

  @reauth_error_message "Stored credentials could not be decrypted with the current encryption key. Please reconnect the integration."

  @doc """
  The canonical error message used when flagging an integration for reauth.
  Exposed so callers that build their own Oban return shapes can embed it.
  """
  @spec reauth_error_message() :: String.t()
  def reauth_error_message, do: @reauth_error_message

  @doc """
  Flags an integration for reauthentication.

  Options (keyword list):

  - `:mark_needs_reauth` — a `(integration, message) -> {:ok, _} | {:error, changeset}`
    function that persists the flag. **Required.**
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

    provider = provider_label_fun.(integration)

    Logger.warning(
      "Integration credentials cannot be decrypted — flagging for reauth",
      integration_type: log_prefix,
      provider: provider,
      integration_id: integration.id,
      user_id: integration.user_id
    )

    case mark_needs_reauth.(integration, @reauth_error_message) do
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
end
