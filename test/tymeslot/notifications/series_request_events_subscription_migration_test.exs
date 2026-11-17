defmodule Tymeslot.Notifications.SeriesRequestEventsSubscriptionMigrationTest do
  @moduledoc """
  Drives `20261114145527_subscribe_automations_to_series_request_events`
  itself: every webhook, Slack and Telegram integration subscribed to
  `meeting.requested`, `meeting.declined` or `meeting.request_expired` gains
  the matching series event, once, and nothing else changes.

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

  @version 20_261_114_145_527

  @channels [
    {:webhook, WebhookSchema},
    {:slack_integration, SlackIntegrationSchema},
    {:telegram_integration, TelegramIntegrationSchema}
  ]

  defp events(schema, row), do: Repo.get!(schema, row.id).events

  for {factory, schema} <- @channels do
    describe "#{factory}" do
      test "adds each series request event beside the event it replaces, once" do
        requested = insert(unquote(factory), events: ["meeting.requested"])

        answered =
          insert(unquote(factory), events: ["meeting.declined", "meeting.request_expired"])

        already =
          insert(unquote(factory), events: ["meeting.requested", "meeting.series_requested"])

        unrelated = insert(unquote(factory), events: ["meeting.created"])

        MigrationRunner.rerun!(@version)
        MigrationRunner.rerun!(@version)

        assert events(unquote(schema), requested) ==
                 ["meeting.requested", "meeting.series_requested"]

        assert events(unquote(schema), answered) == [
                 "meeting.declined",
                 "meeting.request_expired",
                 "meeting.series_declined",
                 "meeting.series_request_expired"
               ]

        assert events(unquote(schema), already) ==
                 ["meeting.requested", "meeting.series_requested"]

        assert events(unquote(schema), unrelated) == ["meeting.created"]
      end
    end
  end
end
