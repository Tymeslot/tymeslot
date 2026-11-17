defmodule Tymeslot.Repo.Migrations.SubscribeAutomationsToSeriesEvents do
  @moduledoc """
  Subscribes the webhooks, Slack and Telegram integrations that already exist
  to the two booking series events, so they keep hearing about series:

    * `meeting.series_created` wherever `meeting.created` is subscribed, since
      a series no longer sends `meeting.created` for each of its sessions;
    * `meeting.series_cancelled` wherever `meeting.cancelled` is subscribed,
      since cancelling the rest of a series no longer sends
      `meeting.cancelled` for each session.

  The event names are restated rather than read from
  `Tymeslot.Notifications.EventTypes`, so the migration means the same thing
  however the code changes later. An integration already subscribed to a
  series event is left as it is, so running it twice adds nothing twice, and
  a `NULL` events list matches nothing. Rolling back leaves the
  subscriptions: a host may have chosen them since.
  """
  use Ecto.Migration

  @tables ~w(webhooks slack_integrations telegram_integrations)

  @pairs [
    {"meeting.created", "meeting.series_created"},
    {"meeting.cancelled", "meeting.series_cancelled"}
  ]

  def up do
    for table <- @tables, {existing, added} <- @pairs do
      # A one-shot data backfill appending to an array column, which has no
      # migration DSL form. It takes row locks only, on the integrations
      # subscribed to `existing`, a small table each.
      # excellent_migrations:safety-assured-for-next-line raw_sql_executed
      execute("""
      UPDATE #{table}
      SET events = array_append(events, '#{added}')
      WHERE '#{existing}' = ANY(events)
        AND NOT ('#{added}' = ANY(events))
      """)
    end
  end

  def down, do: :ok
end
