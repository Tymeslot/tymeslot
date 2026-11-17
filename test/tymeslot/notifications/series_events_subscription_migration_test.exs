defmodule Tymeslot.Notifications.SeriesEventsSubscriptionMigrationTest do
  @moduledoc """
  Drives `20261114121110_subscribe_automations_to_series_events` itself: every
  webhook, Slack and Telegram integration subscribed to `meeting.created` or
  `meeting.cancelled` gains the matching series event, once, and nothing else
  changes.

  The migration module is loaded from `priv` and run through `Ecto.Migrator`;
  see `Tymeslot.Test.MigrationRunner`.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :database
  @moduletag :migrations
  @moduletag :automation

  alias Tymeslot.Repo
  alias Tymeslot.Slack.SlackIntegrationSchema
  alias Tymeslot.Telegram.TelegramIntegrationSchema
  alias Tymeslot.Test.MigrationRunner
  alias Tymeslot.Webhooks.WebhookSchema

  @version 20_261_114_121_110

  @channels [
    {:webhook, WebhookSchema},
    {:slack_integration, SlackIntegrationSchema},
    {:telegram_integration, TelegramIntegrationSchema}
  ]

  defp events(schema, row), do: Repo.get!(schema, row.id).events

  for {factory, schema} <- @channels do
    describe "#{factory}" do
      test "adds each series event beside the event it replaces, once" do
        created = insert(unquote(factory), events: ["meeting.created"])
        cancelled = insert(unquote(factory), events: ["meeting.cancelled", "meeting.rescheduled"])
        both = insert(unquote(factory), events: ["meeting.created", "meeting.cancelled"])

        already =
          insert(unquote(factory), events: ["meeting.created", "meeting.series_created"])

        unrelated = insert(unquote(factory), events: ["meeting.rescheduled"])

        MigrationRunner.rerun!(@version)
        MigrationRunner.rerun!(@version)

        assert events(unquote(schema), created) == ["meeting.created", "meeting.series_created"]

        assert events(unquote(schema), cancelled) ==
                 ["meeting.cancelled", "meeting.rescheduled", "meeting.series_cancelled"]

        assert events(unquote(schema), both) == [
                 "meeting.created",
                 "meeting.cancelled",
                 "meeting.series_created",
                 "meeting.series_cancelled"
               ]

        assert events(unquote(schema), already) == ["meeting.created", "meeting.series_created"]
        assert events(unquote(schema), unrelated) == ["meeting.rescheduled"]
      end
    end
  end
end
