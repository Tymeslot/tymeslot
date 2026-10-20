defmodule TymeslotWeb.Dashboard.Calendar.SyncStatus do
  @moduledoc """
  Which of the organiser's accounts the calendar surface shows as syncing
  (`syncing_ids`) and which as failing.

  The surface asks for a sync of every stale account when it opens
  (`refresh_stale/1`) and of one account on Sync now or Retry
  (`sync_account/2`). A completed sync clears the account (`finished/2`); a
  failed or discarded one stops its spinner (`failed/2`, from the broadcast
  in `Tymeslot.Workers.CalendarSyncJob`); a spinner nothing answers stops
  after `@timeout` (`timed_out/2`).

  The broadcast comes after every failed attempt, including ones Oban will
  retry, so one failure is not news. Failures are counted per account since
  its last success, and the banner names an account (`failed_ids/1`) only
  once it has failed `@persistent` times in a row. A broadcast naming an
  integration the surface does not show (one deleted mid-sync) is ignored.
  The counts start from the persisted ones (`load_persisted/1`), so an
  account that has been failing for hours is named as soon as the calendar
  opens.

  Each request's timer carries a ref (`sync_refs`), so the timer of an
  earlier request cannot stop the spinner of a later one.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 2]
  import Phoenix.LiveView, only: [send_update_after: 3]

  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.SyncProblems
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Dashboard.Calendar.CalendarSurface
  alias TymeslotWeb.Dashboard.Calendar.Toast

  @timeout 60_000

  # Consecutive failed attempts before the banner speaks.
  @persistent 2

  @type socket :: Phoenix.LiveView.Socket.t()

  @doc "Starts the failure counts from the persisted ones, for the shown accounts."
  @spec load_persisted(socket()) :: socket()
  def load_persisted(socket) do
    counts = CalendarGrid.sync_failures(socket.assigns.current_user.id)
    shown = Enum.map(socket.assigns.integrations, & &1.id)

    assign(socket, failure_counts: Map.take(counts, shown))
  end

  @doc """
  Asks for a sync of every stale account, leaving one whose sync is waiting
  out an error's backoff to it (`Freshness.request_sync/3`).
  """
  @spec refresh_stale(socket()) :: socket()
  def refresh_stale(socket) do
    failing = failed_ids(socket.assigns)

    socket.assigns.integrations
    |> CalendarGrid.stale_integrations()
    |> Enum.reject(&(&1.needs_reauth or MapSet.member?(failing, &1.id)))
    |> Enum.reduce(socket, &request(&2, &1.id, :opened))
  end

  @doc """
  Sync now or Retry for one account, named by the button's value. Counted
  against the `:calendar_refresh` limit; opening the calendar is not
  (`refresh_stale/1`).
  """
  @spec sync_account(socket(), String.t() | integer()) :: socket()
  def sync_account(socket, id) do
    with {integration_id, ""} <- Integer.parse(to_string(id)),
         true <- shown?(socket, integration_id) do
      case RateLimiter.check(:calendar_refresh, socket.assigns.current_user.id) do
        :ok ->
          request(socket, integration_id)

        {:error, :rate_limited, _message} ->
          too_many(socket)

        {:error, _other} ->
          too_many(socket)
      end
    else
      _not_theirs -> socket
    end
  end

  @doc "A sync of `integration_id` completed; `nil` when the message named none."
  @spec finished(socket(), integer() | nil) :: socket()
  def finished(socket, nil), do: socket

  def finished(socket, integration_id),
    do:
      assign(socket,
        syncing_ids: MapSet.delete(socket.assigns.syncing_ids, integration_id),
        sync_refs: Map.delete(socket.assigns.sync_refs, integration_id),
        failure_counts: Map.delete(socket.assigns.failure_counts, integration_id)
      )

  @doc """
  An attempt to sync `integration_id` failed or was discarded. `:unknown`
  when the surface does not show that integration, so nothing changed.
  """
  @spec failed(socket(), integer()) :: {:ok, socket()} | :unknown
  def failed(socket, integration_id) do
    if shown?(socket, integration_id),
      do:
        {:ok,
         assign(socket,
           syncing_ids: MapSet.delete(socket.assigns.syncing_ids, integration_id),
           sync_refs: Map.delete(socket.assigns.sync_refs, integration_id),
           failure_counts: Map.update(socket.assigns.failure_counts, integration_id, 1, &(&1 + 1))
         )},
      else: :unknown
  end

  @doc """
  Nothing answered the request `ref` for `integration_id` in time; stop
  showing it. A timer of an earlier request (a different ref) does nothing.
  """
  @spec timed_out(socket(), integer(), reference()) :: socket()
  def timed_out(socket, integration_id, ref) do
    if socket.assigns.sync_refs[integration_id] == ref,
      do:
        assign(socket,
          syncing_ids: MapSet.delete(socket.assigns.syncing_ids, integration_id),
          sync_refs: Map.delete(socket.assigns.sync_refs, integration_id)
        ),
      else: socket
  end

  @doc "The accounts whose failure has persisted: what the banner names."
  @spec failed_ids(map()) :: MapSet.t()
  def failed_ids(%{failure_counts: counts}),
    do: for({id, count} <- counts, count >= @persistent, into: MapSet.new(), do: id)

  @doc "What the banner and the rail read: the problems, their account ids and the accounts needing reauthorisation."
  @spec view(map()) :: %{sync_problems: list(), problem_ids: MapSet.t(), reauth_ids: MapSet.t()}
  def view(assigns) do
    problems = SyncProblems.list(assigns.integrations, assigns.window_events, failed_ids(assigns))

    %{
      sync_problems: problems,
      problem_ids: MapSet.new(problems, & &1.integration_id),
      reauth_ids: MapSet.new(for(%{needs_reauth: true, id: id} <- assigns.integrations, do: id))
    }
  end

  defp too_many(socket),
    do:
      Toast.show(
        socket,
        dgettext(
          "dashboard_calendar",
          "You've asked for several syncs recently. Try again in a few minutes."
        )
      )

  defp shown?(socket, integration_id),
    do: Enum.any?(socket.assigns.integrations, &(&1.id == integration_id))

  defp request(socket, integration_id, how \\ :requested) do
    case CalendarGrid.request_sync(socket.assigns.current_user.id, integration_id, how) do
      :ok ->
        ref = make_ref()

        send_update_after(
          CalendarSurface,
          [
            id: socket.assigns.id,
            action: :sync_timeout,
            integration_id: integration_id,
            ref: ref
          ],
          @timeout
        )

        assign(socket,
          syncing_ids: MapSet.put(socket.assigns.syncing_ids, integration_id),
          sync_refs: Map.put(socket.assigns.sync_refs, integration_id, ref)
        )

      :backing_off ->
        socket

      {:error, _reason} ->
        socket
    end
  end
end
