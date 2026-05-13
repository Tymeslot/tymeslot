defmodule Tymeslot.Notifications.IntegrationQueriesTest do
  use Tymeslot.DataCase, async: true

  @moduletag :notifications
  @moduletag :queries

  import Ecto.Query, only: [from: 2]
  import Tymeslot.Factory

  alias Tymeslot.Notifications.IntegrationQueries
  alias Tymeslot.Slack.SlackIntegrationSchema
  alias Tymeslot.Telegram.TelegramIntegrationSchema

  # Each shared function is exercised against BOTH provider schemas to prove
  # the schema-parameterised boundary really works for every provider, not
  # just one. New providers should be added to this matrix as they land.

  for {provider, factory, schema} <- [
        {:slack, :slack_integration, SlackIntegrationSchema},
        {:telegram, :telegram_integration, TelegramIntegrationSchema}
      ] do
    describe "list_for_user/2 (#{provider})" do
      test "returns integrations for the user, newest first" do
        user = insert(:user)
        now = DateTime.utc_now(:second)
        _other_user = insert(unquote(factory))
        old = insert(unquote(factory), user: user, inserted_at: DateTime.add(now, -60, :second))
        new = insert(unquote(factory), user: user, inserted_at: now)

        result = IntegrationQueries.list_for_user(unquote(schema), user.id)

        assert Enum.map(result, & &1.id) == [new.id, old.id]
      end

      test "returns [] when the user has none" do
        user = insert(:user)
        assert IntegrationQueries.list_for_user(unquote(schema), user.id) == []
      end
    end

    describe "get/2 (#{provider})" do
      test "returns {:ok, row} when found" do
        integration = insert(unquote(factory))

        assert {:ok, found} = IntegrationQueries.get(unquote(schema), integration.id)
        assert found.id == integration.id
      end

      test "returns {:error, :not_found} when missing" do
        assert {:error, :not_found} =
                 IntegrationQueries.get(unquote(schema), -1)
      end
    end

    describe "get_for_user/3 (#{provider})" do
      test "returns {:ok, row} when ID and user match" do
        integration = insert(unquote(factory))

        assert {:ok, found} =
                 IntegrationQueries.get_for_user(
                   unquote(schema),
                   integration.id,
                   integration.user_id
                 )

        assert found.id == integration.id
      end

      test "returns {:error, :not_found} when user does not match" do
        integration = insert(unquote(factory))
        other_user = insert(:user)

        assert {:error, :not_found} =
                 IntegrationQueries.get_for_user(
                   unquote(schema),
                   integration.id,
                   other_user.id
                 )
      end
    end

    describe "delete/1 (#{provider})" do
      test "removes the row" do
        integration = insert(unquote(factory))

        assert {:ok, _deleted} = IntegrationQueries.delete(integration)

        assert {:error, :not_found} =
                 IntegrationQueries.get(unquote(schema), integration.id)
      end
    end

    describe "increment_failure/2 (#{provider})" do
      test "atomically increments failure_count" do
        integration = insert(unquote(factory), failure_count: 2)

        assert {:ok, updated} =
                 IntegrationQueries.increment_failure(unquote(schema), integration.id)

        assert updated.failure_count == 3
      end

      test "returns {:error, :not_found} when row is gone" do
        assert {:error, :not_found} =
                 IntegrationQueries.increment_failure(unquote(schema), -1)
      end
    end

    describe "list_active_for_event/3 (#{provider})" do
      test "returns active integrations subscribed to the event" do
        user = insert(:user)

        active =
          insert(unquote(factory),
            user: user,
            events: ["meeting.created"],
            is_active: true
          )

        _inactive =
          insert(unquote(factory),
            user: user,
            events: ["meeting.created"],
            is_active: false
          )

        _disabled =
          insert(unquote(factory),
            user: user,
            events: ["meeting.created"],
            is_active: true,
            disabled_at: DateTime.utc_now(),
            disabled_reason: "test"
          )

        _wrong_event =
          insert(unquote(factory),
            user: user,
            events: ["meeting.cancelled"],
            is_active: true
          )

        result =
          IntegrationQueries.list_active_for_event(
            unquote(schema),
            user.id,
            "meeting.created"
          )

        assert Enum.map(result, & &1.id) == [active.id]
      end
    end

    describe "toggle_active/2 (#{provider})" do
      test "flips is_active" do
        integration = insert(unquote(factory), is_active: true)

        assert {:ok, toggled} =
                 IntegrationQueries.toggle_active(unquote(schema), integration)

        assert toggled.is_active == false

        assert {:ok, toggled_again} =
                 IntegrationQueries.toggle_active(unquote(schema), toggled)

        assert toggled_again.is_active == true
      end
    end

    describe "record_success/2 (#{provider})" do
      test "stamps last_triggered_at and resets failure_count" do
        integration = insert(unquote(factory), failure_count: 5)

        assert {:ok, updated} =
                 IntegrationQueries.record_success(unquote(schema), integration)

        assert updated.failure_count == 0
        assert %DateTime{} = updated.last_triggered_at
      end
    end

    describe "enable/2 (#{provider})" do
      test "re-enables an auto-disabled integration" do
        integration =
          insert(unquote(factory),
            is_active: false,
            disabled_at: DateTime.utc_now(),
            disabled_reason: "too many failures",
            failure_count: 11
          )

        assert {:ok, enabled} = IntegrationQueries.enable(unquote(schema), integration)

        assert enabled.is_active == true
        assert is_nil(enabled.disabled_at)
        assert is_nil(enabled.disabled_reason)
        assert enabled.failure_count == 0
      end
    end
  end

  describe "delete_stubs_older_than/2" do
    test "deletes slack stubs older than the TTL" do
      user = insert(:user)
      now = DateTime.utc_now(:second)

      stale =
        insert(:slack_integration,
          user: user,
          channel_id: nil,
          inserted_at: DateTime.add(now, -120 * 60, :second)
        )

      fresh =
        insert(:slack_integration,
          user: user,
          channel_id: nil,
          inserted_at: now
        )

      query =
        from(i in SlackIntegrationSchema, where: i.user_id == ^user.id and is_nil(i.channel_id))

      assert {1, _rows} = IntegrationQueries.delete_stubs_older_than(query, 30)

      assert {:error, :not_found} = IntegrationQueries.get(SlackIntegrationSchema, stale.id)
      assert {:ok, _row} = IntegrationQueries.get(SlackIntegrationSchema, fresh.id)
    end

    test "deletes telegram stubs older than the TTL" do
      user = insert(:user)
      now = DateTime.utc_now(:second)

      stale =
        insert(:telegram_integration,
          user: user,
          chat_id: nil,
          inserted_at: DateTime.add(now, -120 * 60, :second)
        )

      fresh =
        insert(:telegram_integration,
          user: user,
          chat_id: nil,
          inserted_at: now
        )

      query =
        from(i in TelegramIntegrationSchema, where: i.user_id == ^user.id and is_nil(i.chat_id))

      assert {1, _rows} = IntegrationQueries.delete_stubs_older_than(query, 30)

      assert {:error, :not_found} = IntegrationQueries.get(TelegramIntegrationSchema, stale.id)
      assert {:ok, _row} = IntegrationQueries.get(TelegramIntegrationSchema, fresh.id)
    end
  end

  describe "delivery_stats/3" do
    test "aggregates slack delivery rows over the period" do
      integration = insert(:slack_integration)

      insert(:slack_delivery, integration: integration, response_status: 200)
      insert(:slack_delivery, integration: integration, response_status: 200)

      insert(:slack_delivery,
        integration: integration,
        response_status: 500,
        error_message: "boom"
      )

      stats =
        IntegrationQueries.delivery_stats(
          Tymeslot.Slack.SlackDeliverySchema,
          integration.id,
          7
        )

      assert stats.total == 3
      assert stats.successful == 2
      assert stats.failed == 1
      assert stats.success_rate == 66.7
      assert stats.period_days == 7
    end

    test "aggregates telegram delivery rows over the period" do
      integration = insert(:telegram_integration)

      insert(:telegram_delivery, integration: integration, response_status: 200)

      insert(:telegram_delivery,
        integration: integration,
        response_status: 400,
        error_message: "bad request"
      )

      stats =
        IntegrationQueries.delivery_stats(
          Tymeslot.Telegram.TelegramDeliverySchema,
          integration.id,
          7
        )

      assert stats.total == 2
      assert stats.successful == 1
      assert stats.failed == 1
      assert stats.success_rate == 50.0
      assert stats.period_days == 7
    end

    test "returns zero success rate when there are no deliveries" do
      integration = insert(:slack_integration)

      stats =
        IntegrationQueries.delivery_stats(
          Tymeslot.Slack.SlackDeliverySchema,
          integration.id,
          7
        )

      assert stats.total == 0
      assert stats.success_rate == 0.0
    end
  end

  # insert/1 and update/1 are exercised through the per-provider facades in
  # SlackQueriesTest / TelegramQueriesTest — they take changesets, so the
  # provider's changeset module is part of the input. The pure Repo.insert /
  # Repo.update wrappers here have nothing schema-specific to validate.

  describe "insert/1" do
    test "inserts a slack integration changeset" do
      user = insert(:user)

      changeset =
        SlackIntegrationSchema.changeset(%SlackIntegrationSchema{}, %{
          user_id: user.id,
          name: "My Workspace",
          app_mode: "oauth",
          bot_token: "xoxb-token",
          team_id: "T1",
          channel_id: "C1",
          events: ["meeting.created"]
        })

      assert {:ok, integration} = IntegrationQueries.insert(changeset)
      assert integration.name == "My Workspace"
    end

    test "inserts a telegram integration changeset" do
      user = insert(:user)

      changeset =
        TelegramIntegrationSchema.changeset(%TelegramIntegrationSchema{}, %{
          user_id: user.id,
          name: "My Channel",
          bot_mode: "own",
          bot_token: "1234567890:ABCdefGHIjklMNOpqrSTUvwxyz123456789",
          chat_id: "999111",
          events: ["meeting.created"]
        })

      assert {:ok, integration} = IntegrationQueries.insert(changeset)
      assert integration.name == "My Channel"
    end

    test "returns {:error, changeset} when invalid" do
      invalid =
        SlackIntegrationSchema.changeset(%SlackIntegrationSchema{}, %{name: nil})

      assert {:error, %Ecto.Changeset{}} = IntegrationQueries.insert(invalid)
    end
  end

  describe "update/1" do
    test "updates a slack integration" do
      integration = insert(:slack_integration)

      changeset = SlackIntegrationSchema.changeset(integration, %{name: "Renamed Slack"})

      assert {:ok, updated} = IntegrationQueries.update(changeset)
      assert updated.name == "Renamed Slack"
    end

    test "updates a telegram integration" do
      integration = insert(:telegram_integration)

      changeset = TelegramIntegrationSchema.changeset(integration, %{name: "Renamed Telegram"})

      assert {:ok, updated} = IntegrationQueries.update(changeset)
      assert updated.name == "Renamed Telegram"
    end
  end
end
