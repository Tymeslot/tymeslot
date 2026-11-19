defmodule Tymeslot.Notifications.Channel do
  @moduledoc """
  The contract a notification channel context (webhooks, Telegram, Slack)
  implements for `Tymeslot.Notifications.ChannelFanout`.

  The fan-out resolves the organiser and the event's wire name and checks
  feature access once per event; the channel only finds its own subscribed
  integrations and schedules one delivery for each. A channel that is
  switched off for the whole instance answers with an empty list.
  """

  @typedoc "One scheduling outcome per integration the channel tried."
  @type outcome :: {integration_id :: integer(), :ok | {:error, term()}}

  @typedoc """
  The `series` object the event carries (`Tymeslot.BookingSeries.Automation`):
  a whole series for a series event, a session's place in its series for an
  event about one session, nil for a booking outside any series. JSON-safe,
  as job args store it.
  """
  @type series :: %{String.t() => term()} | nil

  @doc """
  Schedules a delivery of `event_type` about `meeting`, carrying `series`,
  to every active integration of `user_id` subscribed to it. Feature access
  is the caller's responsibility; this is called only by
  `ChannelFanout.dispatch/3`.
  """
  @callback schedule_for_event(
              user_id :: integer(),
              event_type :: String.t(),
              meeting :: map(),
              series :: series()
            ) :: [outcome()]
end
