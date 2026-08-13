defmodule Tymeslot.Integrations.Calendar.SyncLink.Teardown do
  @moduledoc """
  Withdraws the placeholders a link has written, in the one order that cannot
  strand them.

  ## Why this cannot be `on_delete: :delete_all`

  Every other row a link owns disappears with it, because every other row is in
  Postgres. A mirror's placeholder is not: it is an event on the organiser's
  *other* calendar, held by Google, Outlook or a CalDAV server, and the only
  thing that names it is the `target_uid` on the mapping row. Cascade the rows
  away and the busy block stays on the calendar forever, owned by nothing,
  removable only by the organiser noticing it and deleting it by hand — and
  since a mirror is deliberately indistinguishable from an ordinary "Busy"
  block, they will not know what it is.

  So the sequence is fixed, and it is the reverse of the intuitive one:

  1. the link is disabled, so nothing enqueues a fresh mirror write into the
     teardown it is racing;
  2. every mapping moves to `pending_delete` in one statement, *before* the
     first provider call, so a crash mid-teardown leaves rows in the state the
     reconcile sweep already looks for and the work resumes rather than
     stalling on rows still claiming to be `active`;
  3. each placeholder is deleted from the provider;
  4. only then is the row dropped.

  ## A failed provider delete is not an error to swallow, or to stop on

  A delete that fails leaves its row in `pending_delete` — untouched, still
  carrying the uid — and the sweep retries it. The failure is still returned to
  the caller, because the callers are destructive operations (deleting a link,
  disconnecting a calendar, deleting an account) and a caller that proceeded
  regardless would destroy the row that names the surviving placeholder. That
  is the whole hazard this module exists to avoid.

  But one failure does not abort the rest. The mirrors of a link are
  independent placeholders on the same calendar, and stopping at the first
  failure would leave the remaining ones behind for no reason beyond the order
  they happened to be listed in. Every mirror is attempted; the first failure
  is what surfaces.

  `{:error, :not_found}` from the provider is a success: the placeholder is
  already gone, and keeping the row would ask the sweep to retry a delete that
  can never succeed.

  ## Why not reuse `Engine.unmirror/3`

  It answers a different question. `unmirror/3` withdraws the placeholder for
  one *source event*, looked up by source uid, and is the sync path's
  operation. Teardown works from the mapping rows themselves — the source may
  be long gone, the source calendar may be the one being disconnected — so it
  drives the delete from the row it already holds rather than from a lookup
  that can miss.
  """

  require Logger

  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkQueries
  alias Tymeslot.Integrations.Calendar.CalendarSyncLinkSchema
  alias Tymeslot.Integrations.Calendar.CalendarSyncMirrorQueries
  alias Tymeslot.Integrations.Calendar.CalendarSyncMirrorSchema
  alias Tymeslot.Integrations.Calendar.Events, as: CalendarEvents

  @typedoc """
  `:ok` when every placeholder is confirmed gone from its provider. The error
  is the first provider failure encountered; the rows behind it are in
  `pending_delete` and the reconcile sweep will retry them.
  """
  @type result :: :ok | {:error, term()}

  @doc """
  Withdraws every placeholder one link has written, leaving the link row itself
  for the caller to delete.

  Deliberately does not delete the link: the caller decides whether the link is
  going away (link removal, integration disconnect) or merely being emptied,
  and deleting it here would cascade the mapping rows away underneath a
  teardown that had not finished with them.
  """
  @spec tear_down_link(CalendarSyncLinkSchema.t(), integer()) :: result()
  def tear_down_link(%CalendarSyncLinkSchema{} = link, user_id) when is_integer(user_id) do
    disable(link)
    CalendarSyncMirrorQueries.mark_pending_delete_for_link(link.id)

    link.id
    |> CalendarSyncMirrorQueries.list_for_link()
    |> Enum.reduce(:ok, fn mirror, outcome ->
      first_error(outcome, withdraw(mirror, link, user_id))
    end)
  end

  @doc """
  Withdraws every placeholder an integration is involved in, in both
  directions.

  A calendar being disconnected is named by two kinds of link, and both leave
  placeholders that must go. As a *target* it holds the placeholders itself. As
  a *source* it caused placeholders on other calendars, and those calendars are
  staying connected — a busy block there, with its source calendar gone, is
  exactly the orphan nothing will ever clean up.

  `user_id` is the acting organiser's, and every link is filtered against it:
  the integration id arrives from a delete request and an unfiltered sweep on
  it would let a forged id withdraw a stranger's mirrors.
  """
  @spec tear_down_for_integration(integer(), integer()) :: result()
  def tear_down_for_integration(integration_id, user_id)
      when is_integer(integration_id) and is_integer(user_id) do
    integration_id
    |> CalendarSyncLinkQueries.list_for_integration()
    |> Enum.filter(&(&1.user_id == user_id))
    |> tear_down_each(user_id)
  end

  @doc """
  Withdraws every placeholder the organiser's links have written anywhere.

  Account deletion's half. The placeholders sit on calendars the account is
  about to lose all access to, so this is the last moment at which they can be
  removed at all — which is why a failure here aborts the deletion rather than
  being logged and passed over.
  """
  @spec tear_down_for_user(integer()) :: result()
  def tear_down_for_user(user_id) when is_integer(user_id) do
    user_id
    |> CalendarSyncLinkQueries.list_for_user()
    |> tear_down_each(user_id)
  end

  # Both directions of an integration disconnect can name the same link, and a
  # user's links are distinct by construction; `uniq_by/2` makes the first case
  # safe without the second having to care.
  defp tear_down_each(links, user_id) do
    links
    |> Enum.uniq_by(& &1.id)
    |> Enum.reduce(:ok, fn link, outcome ->
      first_error(outcome, tear_down_link(link, user_id))
    end)
  end

  # Pausing first is what stops the sync path enqueueing a write for a mirror
  # this teardown is in the middle of removing. It is best-effort: a link whose
  # update fails is still torn down, because the alternative — refusing to
  # withdraw the placeholders — is the strictly worse outcome.
  defp disable(%CalendarSyncLinkSchema{enabled: false}), do: :ok

  defp disable(%CalendarSyncLinkSchema{} = link) do
    case CalendarSyncLinkQueries.update(link, %{"enabled" => false}) do
      {:ok, _updated} ->
        :ok

      {:error, changeset} ->
        Logger.warning("Failed to disable sync link before teardown",
          sync_link_id: link.id,
          reason: inspect(changeset.errors)
        )

        :ok
    end
  end

  defp withdraw(%CalendarSyncMirrorSchema{} = mirror, link, user_id) do
    case CalendarEvents.delete_event(mirror.target_uid, {mirror.target_integration_id, user_id}) do
      :ok ->
        drop(mirror)

      # Already gone on the provider. Keeping the row would ask the sweep to
      # retry a delete that can never succeed.
      {:error, :not_found} ->
        drop(mirror)

      {:error, reason} ->
        Logger.warning("Failed to withdraw mirror placeholder during teardown",
          sync_link_id: link.id,
          target_integration_id: mirror.target_integration_id,
          target_uid: mirror.target_uid,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  # The row is dropped only here, after the provider has confirmed. A delete
  # that fails to drop the row is still a placeholder successfully removed, so
  # the row is left in `pending_delete` for the sweep to finish rather than
  # reported as a placeholder still standing.
  defp drop(mirror) do
    case CalendarSyncMirrorQueries.delete(mirror) do
      {:ok, _deleted} ->
        :ok

      {:error, changeset} ->
        Logger.warning("Withdrew mirror placeholder but could not drop its mapping row",
          sync_link_id: mirror.sync_link_id,
          target_uid: mirror.target_uid,
          reason: inspect(changeset.errors)
        )

        :ok
    end
  end

  defp first_error({:error, _reason} = already, _next), do: already
  defp first_error(:ok, next), do: next
end
