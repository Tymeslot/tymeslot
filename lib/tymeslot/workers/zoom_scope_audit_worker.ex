defmodule Tymeslot.Workers.ZoomScopeAuditWorker do
  @moduledoc """
  Nightly audit flagging Zoom integrations whose OAuth grant cannot perform
  every meeting operation Tymeslot needs.

  Zoom's granular apps issue one scope per action, and a grant only ever holds
  the scopes that were requested when the user consented. Widening the request
  therefore leaves every existing grant short: those users keep a connected,
  healthy-looking integration that silently cannot reschedule (or cancel) a
  meeting until they reconnect.

  Waiting for the failure to surface means the user finds out when a booking
  moves, which is the worst possible moment. This audit finds them first,
  flagging the integration through the same path the runtime rejection uses, so
  the dashboard shows "Reconnect" and the account owner is emailed once.

  A gap is only the user's to close when the scope is one Tymeslot actually
  asks Zoom for. A scope absent from the authorize request is absent from every
  grant, so it says nothing about any particular user's consent and no amount
  of reconnecting will produce it: that is the Zoom app's shortfall, and it is
  reported to the operator rather than pushed onto the account owner. Since
  nothing is flagged and nothing is emailed in that case, the count this worker
  logs is the only signal that rescheduling is broken at all.

  The scan converges: flagging sets `needs_reauth`, and an already-flagged
  integration is skipped, so a steady state costs one query and no writes. It
  self-heals too — reconnecting clears the flag, and a grant that then holds
  every scope never matches again. That also makes it the safety net for a
  self-hosted deployment whose own Zoom app is missing a scope, which no
  one-off backfill would ever catch.
  """

  use Oban.Worker, queue: :default, max_attempts: 1, unique: [period: 60]

  alias Tymeslot.Integrations.Video.Providers.ZoomProvider.Reauth
  alias Tymeslot.Integrations.Video.Providers.ZoomProvider.Scopes
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries

  require Logger

  @provider "zoom"

  @impl Oban.Worker
  def perform(_job) do
    tally =
      @provider
      |> VideoIntegrationQueries.list_active_by_provider()
      |> Enum.map(&audit/1)
      |> Enum.frequencies()

    report(tally)

    :ok
  end

  # Already flagged: the user has the badge and the email, and re-flagging would
  # only overwrite a message that may describe a different, equally true problem.
  defp audit(%{needs_reauth: true}), do: :already_flagged

  # A stale grant takes priority over an app-level gap. Reconnecting genuinely
  # closes the first, and it stays worth asking for even when the second also
  # applies and will survive it.
  defp audit(integration) do
    scope = integration.oauth_scope || ""

    case stale_operation(scope) do
      nil -> if blocked?(scope), do: :app_scope_missing, else: :satisfied
      operation -> flag_and_report(integration, operation)
    end
  end

  # The first operation the user could restore by reconnecting, in lifecycle
  # order, so the message names the earliest thing that will break. Only scopes
  # Tymeslot actually asks Zoom for qualify: the rest are missing from every
  # grant and would mask a gap that reconnecting can close.
  defp stale_operation(scope) do
    Scopes.operations()
    |> Enum.filter(&Scopes.requestable?/1)
    |> Enum.find(&(not Scopes.satisfied?(scope, &1)))
  end

  # An operation no grant can satisfy, because its scope is never requested.
  defp blocked?(scope) do
    Scopes.operations()
    |> Enum.reject(&Scopes.requestable?/1)
    |> Enum.any?(&(not Scopes.satisfied?(scope, &1)))
  end

  defp flag_and_report(integration, operation) do
    Logger.warning("Zoom grant is missing a scope Tymeslot needs",
      integration_id: integration.id,
      operation: operation,
      required_scope: Scopes.required_description(operation)
    )

    flag(integration, operation)
    :flagged
  end

  # The blocked count is the one signal an operator gets that rescheduling is
  # broken for everyone: with nothing flagged and nothing emailed, this line is
  # all that stands between a silent failure and a noticed one.
  defp report(tally) do
    blocked = Map.get(tally, :app_scope_missing, 0)

    if blocked > 0 do
      Logger.error(
        "Zoom integrations blocked by a scope the Zoom app does not request; " <>
          "users cannot fix this by reconnecting",
        integrations: blocked,
        missing_operations: inspect(Enum.reject(Scopes.operations(), &Scopes.requestable?/1))
      )
    end

    Logger.info("Zoom scope audit complete",
      flagged: Map.get(tally, :flagged, 0),
      blocked: blocked
    )
  end

  # Flagged through the provider's own reauth module, so the audit and the
  # runtime rejection record the same event with the same wording, and the
  # guard against asking a user to fix an app-level gap cannot be bypassed by
  # coming in this way.
  defp flag(integration, operation) do
    Reauth.flag_missing_scope(
      %{integration_id: integration.id, user_id: integration.user_id},
      operation
    )
  end
end
