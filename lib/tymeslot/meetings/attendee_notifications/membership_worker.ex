defmodule Tymeslot.Meetings.AttendeeNotifications.MembershipWorker do
  @moduledoc """
  Invites the guests a dashboard edit added, and tells the ones it removed,
  once that edit, saved to sync later because the calendar could not be
  reached, has been replayed to it.

  Enqueued by `Dispatcher.schedule_membership/4` from
  `AttendeeNotifications.membership_changed/3`, with the attendees as they
  stood before the first change saved. Until the replay has succeeded the
  job snoozes (`ReplayWait`); once it has, the emails are worked out from
  those attendees and the event as the replay left it, so a guest added and
  removed again before the replay hears nothing, and a later saved change
  does not invite or cancel anyone twice.

  An event gone by then, deleted or dropped by the replay as elapsed, owes
  nobody anything here: the delete tells its own guests.
  """

  use Oban.Worker, queue: :emails, max_attempts: 5

  require Logger

  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Meetings.AttendeeNotifications
  alias Tymeslot.Meetings.AttendeeNotifications.ReplayWait
  alias Tymeslot.Repo

  @impl Oban.Worker
  def perform(
        %Oban.Job{
          args: %{
            "calendar_integration_id" => integration_id,
            "uid" => uid,
            "attendees_before" => attendees_before,
            "owner_user_id" => owner_user_id
          }
        } = job
      ) do
    case ProviderCalendarEventQueries.get_by_uid(integration_id, uid) do
      {:error, :not_found} ->
        Logger.info("AttendeeNotifications.MembershipWorker skipped — event not found",
          calendar_integration_id: integration_id
        )

        :ok

      {:ok, event} ->
        if ReplayWait.awaiting_replay?(event),
          do: ReplayWait.wait(job),
          else: tell(%{attendees: attendees_before}, event, owner_user_id)
    end
  end

  # In one transaction, so that a failure to schedule one email rolls back
  # the others and the retry sends each exactly once.
  defp tell(before, event, owner_user_id) do
    result =
      Repo.transaction(fn ->
        before
        |> AttendeeNotifications.membership_changed(event, owner_user_id)
        |> Map.values()
        |> Enum.find_value(fn
          {:error, reason} -> Repo.rollback(reason)
          _ok -> nil
        end)
      end)

    case result do
      {:ok, _nothing} ->
        :ok

      {:error, reason} = error ->
        Logger.error("AttendeeNotifications.MembershipWorker failed",
          calendar_integration_id: event.calendar_integration_id,
          reason: LogFormat.reason(reason)
        )

        error
    end
  end
end
