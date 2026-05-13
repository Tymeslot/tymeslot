defmodule Tymeslot.Slack.SlackIntegrationSchemaTest do
  use Tymeslot.DataCase, async: true

  @moduletag :schema
  @moduletag :slack

  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Repo
  alias Tymeslot.Slack.SlackIntegrationSchema

  @valid_oauth_attrs %{
    # set in setup
    user_id: nil,
    name: "My Workspace",
    app_mode: "oauth",
    bot_token: "xoxb-fake-token",
    team_id: "T123",
    team_name: "Acme",
    channel_id: "C456",
    channel_name: "#bookings",
    events: ["meeting.created", "meeting.cancelled"]
  }

  @valid_webhook_attrs %{
    user_id: nil,
    name: "Slack via webhook",
    app_mode: "webhook_url",
    webhook_url: "https://hooks.slack.com/services/T1/B2/abc123",
    events: ["meeting.created"]
  }

  setup do
    user = insert(:user)
    {:ok, user: user}
  end

  describe "changeset/2 — OAuth mode" do
    test "valid attrs produce a valid changeset", %{user: user} do
      attrs = %{@valid_oauth_attrs | user_id: user.id}
      cs = SlackIntegrationSchema.changeset(%SlackIntegrationSchema{}, attrs)
      assert cs.valid?
    end

    test "encrypts bot_token", %{user: user} do
      attrs = %{@valid_oauth_attrs | user_id: user.id}
      cs = SlackIntegrationSchema.changeset(%SlackIntegrationSchema{}, attrs)
      assert {:ok, integration} = Repo.insert(cs)
      refute integration.bot_token_encrypted == "xoxb-fake-token"
      assert SlackIntegrationSchema.bot_token(integration) == "xoxb-fake-token"
    end

    test "requires bot_token and channel_id in oauth mode", %{user: user} do
      attrs = Map.drop(%{@valid_oauth_attrs | user_id: user.id}, [:bot_token, :channel_id])
      cs = SlackIntegrationSchema.changeset(%SlackIntegrationSchema{}, attrs)
      refute cs.valid?
      errors = errors_on(cs)
      assert "can't be blank" in errors.bot_token
      assert "can't be blank" in errors.channel_id
    end
  end

  describe "changeset/2 — webhook_url mode" do
    test "valid attrs produce a valid changeset", %{user: user} do
      attrs = %{@valid_webhook_attrs | user_id: user.id}
      cs = SlackIntegrationSchema.changeset(%SlackIntegrationSchema{}, attrs)
      assert cs.valid?
    end

    test "encrypts webhook_url", %{user: user} do
      attrs = %{@valid_webhook_attrs | user_id: user.id}

      {:ok, integration} =
        %SlackIntegrationSchema{}
        |> SlackIntegrationSchema.changeset(attrs)
        |> Repo.insert()

      refute integration.webhook_url_encrypted == attrs.webhook_url
      assert SlackIntegrationSchema.webhook_url(integration) == attrs.webhook_url
    end

    test "rejects malformed webhook URLs", %{user: user} do
      attrs = %{
        @valid_webhook_attrs
        | user_id: user.id,
          webhook_url: "http://example.com/foo"
      }

      cs = SlackIntegrationSchema.changeset(%SlackIntegrationSchema{}, attrs)
      refute cs.valid?
      assert %{webhook_url: [msg]} = errors_on(cs)
      assert msg =~ "must be a Slack webhook URL"
    end
  end

  describe "status/1" do
    test "returns :pending_oauth when oauth mode lacks channel_id", %{user: user} do
      attrs = Map.drop(%{@valid_oauth_attrs | user_id: user.id}, [:channel_id])
      integration = build_struct(attrs)
      assert SlackIntegrationSchema.status(integration) == :pending_oauth
    end

    test "returns :auto_disabled when disabled_at is set", %{user: user} do
      attrs = %{@valid_oauth_attrs | user_id: user.id}
      integration = Map.put(build_struct(attrs), :disabled_at, DateTime.utc_now())
      assert SlackIntegrationSchema.status(integration) == :auto_disabled
    end

    test "returns :paused when is_active is false", %{user: user} do
      attrs = %{@valid_oauth_attrs | user_id: user.id}
      integration = Map.put(build_struct(attrs), :is_active, false)
      assert SlackIntegrationSchema.status(integration) == :paused
    end

    test "returns :active when everything is set and enabled", %{user: user} do
      attrs = %{@valid_oauth_attrs | user_id: user.id}
      integration = build_struct(attrs)
      assert SlackIntegrationSchema.status(integration) == :active
    end
  end

  describe "subscribed_to?/2" do
    test "true when event is in the events list", %{user: user} do
      attrs = %{@valid_oauth_attrs | user_id: user.id}
      integration = build_struct(attrs)
      assert SlackIntegrationSchema.subscribed_to?(integration, "meeting.created")
      refute SlackIntegrationSchema.subscribed_to?(integration, "meeting.rescheduled")
    end
  end

  describe "oauth_init_changeset/2" do
    test "accepts attrs without channel_id and encrypts the bot_token", %{user: user} do
      attrs = %{
        user_id: user.id,
        name: "My Workspace",
        app_mode: "oauth",
        bot_token: "xoxb-init-token",
        team_id: "T123",
        team_name: "Acme",
        authed_user_id: "U7",
        scope: "chat:write,channels:read",
        link_token: "linktok",
        events: ["meeting.created"]
      }

      cs = SlackIntegrationSchema.oauth_init_changeset(%SlackIntegrationSchema{}, attrs)
      assert cs.valid?

      assert {:ok, integration} = Repo.insert(cs)
      assert is_nil(integration.channel_id)
      refute integration.bot_token_encrypted == "xoxb-init-token"
      assert SlackIntegrationSchema.bot_token(integration) == "xoxb-init-token"
    end

    test "requires user_id, name, app_mode, bot_token, team_id" do
      cs = SlackIntegrationSchema.oauth_init_changeset(%SlackIntegrationSchema{}, %{})
      refute cs.valid?
      errors = errors_on(cs)
      assert "can't be blank" in errors.user_id
      assert "can't be blank" in errors.name
      assert "can't be blank" in errors.app_mode
      assert "can't be blank" in errors.bot_token
      assert "can't be blank" in errors.team_id
    end

    test "status/1 returns :pending_oauth for an oauth-mode record without channel_id", %{
      user: user
    } do
      attrs = %{
        user_id: user.id,
        name: "Pending",
        app_mode: "oauth",
        bot_token: "xoxb-pending",
        team_id: "T999",
        events: ["meeting.created"]
      }

      integration =
        %SlackIntegrationSchema{}
        |> SlackIntegrationSchema.oauth_init_changeset(attrs)
        |> Changeset.apply_changes()

      assert SlackIntegrationSchema.status(integration) == :pending_oauth
    end
  end

  describe "set_channel_changeset/2" do
    test "transitions a pending integration to active by setting channel_id", %{user: user} do
      pending_attrs = %{
        user_id: user.id,
        name: "Pending",
        app_mode: "oauth",
        bot_token: "xoxb-pending",
        team_id: "T1",
        events: ["meeting.created"]
      }

      {:ok, pending} =
        %SlackIntegrationSchema{}
        |> SlackIntegrationSchema.oauth_init_changeset(pending_attrs)
        |> Repo.insert()

      assert SlackIntegrationSchema.status(pending) == :pending_oauth

      cs =
        SlackIntegrationSchema.set_channel_changeset(pending, %{
          channel_id: "C42",
          channel_name: "#bookings"
        })

      assert cs.valid?
      assert {:ok, updated} = Repo.update(cs)
      assert updated.channel_id == "C42"
      assert updated.channel_name == "#bookings"
      assert SlackIntegrationSchema.status(updated) == :active
    end

    test "requires channel_id", %{user: user} do
      pending = build_pending(user)

      cs = SlackIntegrationSchema.set_channel_changeset(pending, %{})
      refute cs.valid?
      assert "can't be blank" in errors_on(cs).channel_id
    end
  end

  defp build_struct(attrs) do
    %SlackIntegrationSchema{}
    |> SlackIntegrationSchema.changeset(attrs)
    |> Changeset.apply_changes()
  end

  defp build_pending(user) do
    %SlackIntegrationSchema{}
    |> SlackIntegrationSchema.oauth_init_changeset(%{
      user_id: user.id,
      name: "Pending",
      app_mode: "oauth",
      bot_token: "xoxb-pending",
      team_id: "T1",
      events: ["meeting.created"]
    })
    |> Changeset.apply_changes()
  end
end
