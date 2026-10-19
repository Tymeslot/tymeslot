defmodule Tymeslot.Notifications.ChannelFanout do
  @moduledoc """
  Fans one booking event out to every notification channel (webhooks,
  Telegram, Slack).

  The organiser, the event's wire name and the organiser's access to
  automations are resolved once per event here, rather than once per
  channel. Each channel is best-effort: one that raises is reported and the
  remaining channels still run, and nothing escapes into the caller.
  Scheduling failures are logged uniformly, except a channel's routine
  `:integration_not_active` answer for an integration that cannot fire.
  """

  require Logger

  alias Tymeslot.Features
  alias Tymeslot.Infrastructure.ErrorTracking
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Notifications.EventTypes
  alias Tymeslot.Slack
  alias Tymeslot.Telegram
  alias Tymeslot.Webhooks

  @channels [webhooks: Webhooks, telegram: Telegram, slack: Slack]

  @doc """
  Schedules `event` (an internal event atom or its wire name) about
  `meeting` on every channel the organiser has subscribed to it.

  Options:

    * `:channels` — the `{name, context}` pairs to fan out to, each context
      implementing `Tymeslot.Notifications.Channel`. Defaults to webhooks,
      Telegram and Slack, in that order.
  """
  @spec dispatch(atom() | String.t(), MeetingSchema.t() | term(), keyword()) ::
          :ok | {:error, :no_organizer | :not_a_meeting | term()}
  def dispatch(event, meeting, opts \\ [])

  def dispatch(event, %MeetingSchema{organizer_user_id: nil} = meeting, _opts) do
    Logger.warning("Cannot dispatch channel notifications: meeting has no organizer_user_id",
      meeting_id: meeting.id,
      event: event
    )

    {:error, :no_organizer}
  end

  def dispatch(event, %MeetingSchema{organizer_user_id: user_id} = meeting, opts) do
    with {:ok, event_type} <- wire_name(event, meeting),
         :ok <- check_access(user_id, event_type) do
      opts
      |> Keyword.get(:channels, @channels)
      |> Enum.each(fn {channel, context} ->
        dispatch_channel(channel, context, user_id, event_type, meeting)
      end)
    end
  end

  # The `Events` entry points take any term; something other than a meeting
  # row reaching the fan-out is reported, not raised into the caller.
  def dispatch(event, _meeting, _opts) do
    Logger.error("Cannot dispatch channel notifications for a non-meeting", event: event)
    {:error, :not_a_meeting}
  end

  # An unknown internal atom raises in `EventTypes`; that is a programming
  # error, reported rather than allowed to abort the caller's fan-out.
  defp wire_name(event, _meeting) when is_binary(event), do: {:ok, event}

  defp wire_name(event, meeting) when is_atom(event) do
    {:ok, EventTypes.to_event_type(event)}
  rescue
    exception ->
      ErrorTracking.report_error(exception, __STACKTRACE__, %{
        channel: :all,
        event: event,
        meeting_id: meeting.id
      })

      {:error, {:dispatch_failed, exception}}
  end

  defp check_access(user_id, event_type) do
    case Features.check_access(user_id, :automations_allowed) do
      :ok ->
        :ok

      {:error, :feature_access_checker_failed} = error ->
        Logger.warning("Feature access check failed, skipping channel notifications",
          user_id: user_id,
          event_type: event_type
        )

        error

      {:error, reason} = error ->
        Logger.debug("Skipping channel notifications without automations access",
          user_id: user_id,
          event_type: event_type,
          reason: reason
        )

        error
    end
  end

  defp dispatch_channel(channel, context, user_id, event_type, meeting) do
    user_id
    |> context.schedule_for_event(event_type, meeting)
    |> Enum.each(&log_outcome(&1, channel, event_type))
  rescue
    exception ->
      ErrorTracking.report_error(exception, __STACKTRACE__, %{
        channel: channel,
        event: event_type,
        meeting_id: meeting.id
      })
  end

  defp log_outcome({_id, :ok}, _channel, _event_type), do: :ok
  defp log_outcome({_id, {:error, :integration_not_active}}, _channel, _event_type), do: :ok

  defp log_outcome({id, {:error, reason}}, channel, event_type) do
    Logger.warning("Failed to schedule channel delivery",
      channel: channel,
      integration_id: id,
      event_type: event_type,
      reason: LogFormat.reason(reason)
    )
  end
end
