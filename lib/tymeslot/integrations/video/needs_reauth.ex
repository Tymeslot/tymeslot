defmodule Tymeslot.Integrations.Video.NeedsReauth do
  @moduledoc """
  Marks a video integration "Reconnect required" from a provider config.

  Providers learn that stored credentials were refused in the middle of a call,
  holding only the runtime config `build_config/3` gave them, not the
  integration row. This is the one path from that config to
  `Tymeslot.Integrations.Video.flag_and_notify/2`, whatever the provider
  authenticates with: a revoked OAuth grant (Zoom, Teams, Google Meet) or a
  refused app password (Nextcloud Talk).
  """

  require Logger

  alias Tymeslot.Integrations.Video

  @doc """
  Marks an integration as needing reconnection, surfacing the "Reconnect
  required" badge on the dashboard's video row and, on the false to true
  transition, emailing the owner.

  Called after credentials were refused server-side, or when an OAuth grant
  predates a scope the provider now requires. A config with no
  `integration_id`/`user_id` has no row to flag, which is logged rather than
  treated as an error: the caller's own failure is already being reported.

  ## Options

    * `:label`: provider name used in log lines. **Required.**
    * `:event`: machine-readable event name, e.g. `"zoom_token_revoked"`.
      **Required.**
    * `:message`: the message the account owner reads on the dashboard, as
      its untranslated msgid (`dgettext_noop/2` in `dashboard_integrations`),
      which the dashboard translates into the viewer's locale. **Required.**
  """
  @spec flag(map(), keyword()) :: :ok
  def flag(config, opts) do
    label = Keyword.fetch!(opts, :label)
    event = Keyword.fetch!(opts, :event)
    message = Keyword.fetch!(opts, :message)

    integration_id = Map.get(config, :integration_id)
    user_id = Map.get(config, :user_id)

    if is_nil(integration_id) or is_nil(user_id) do
      Logger.warning("Video integration needs reauth but no integration_id to flag",
        provider: label,
        event: event
      )
    else
      Logger.warning("Flagging video integration for reauth",
        provider: label,
        event: event,
        integration_id: integration_id
      )

      mark_needs_reauth(integration_id, user_id, message)
    end

    :ok
  end

  # Delegates to `Video.flag_and_notify/2`, the same false to true seam used by
  # `Video.handle_reauth_required/2`, so the two paths cannot drift on whether
  # reconnecting is announced.
  defp mark_needs_reauth(integration_id, user_id, message) do
    case Video.fetch_integration_for_user(integration_id, user_id) do
      {:ok, integration} -> Video.flag_and_notify(integration, message)
      {:error, :not_found} -> :ok
    end
  end
end
