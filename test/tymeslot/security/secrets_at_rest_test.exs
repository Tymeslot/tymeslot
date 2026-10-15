defmodule Tymeslot.Security.SecretsAtRestTest do
  @moduledoc """
  The secrets and capability tokens kept outside the credential tables reach
  the database encrypted or hashed, never as the value itself: a leaked
  backup, a SQL console or a replica must not hand over a working webhook,
  meeting passcode or link.

  Each test writes a known value through the schema and reads the raw row
  back with SQL, below the schema's own decoding.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :security
  @moduletag :schema

  alias Ecto.UUID
  alias Tymeslot.FreeBusy
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Polls
  alias Tymeslot.Polls.PollSchema
  alias Tymeslot.Polls.Voting
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Security.Token
  alias Tymeslot.Telegram
  alias Tymeslot.Webhooks.WebhookSchema

  describe "encrypted secrets" do
    test "a webhook URL" do
      url = "https://hooks.zapier.com/hooks/catch/123/secret-path"
      webhook = insert(:webhook, url: url)

      assert_encrypted("webhooks", webhook.id, "url", url)
      assert Repo.get!(WebhookSchema, webhook.id).url == url
    end

    test "a custom meeting link" do
      url = "https://zoom.us/j/123456?pwd=passcode"
      integration = insert(:video_integration, provider: "custom", custom_meeting_url: url)

      assert_encrypted("video_integrations", integration.id, "custom_meeting_url", url)
      assert Repo.get!(VideoIntegrationSchema, integration.id).custom_meeting_url == url
    end

    test "a Google push channel secret" do
      integration = insert(:calendar_integration, google_channel_secret: "channel-secret")

      assert_encrypted(
        "calendar_integrations",
        integration.id,
        "google_channel_secret",
        "channel-secret"
      )

      assert Repo.get!(CalendarIntegrationSchema, integration.id).google_channel_secret ==
               "channel-secret"
    end

    test "an Outlook subscription client state" do
      integration = insert(:calendar_integration, graph_client_state: "client-state")

      assert_encrypted(
        "calendar_integrations",
        integration.id,
        "graph_client_state",
        "client-state"
      )

      assert Repo.get!(CalendarIntegrationSchema, integration.id).graph_client_state ==
               "client-state"
    end
  end

  describe "hashed tokens" do
    test "a Telegram link token, cleared once it links a chat" do
      integration = insert(:telegram_integration, bot_mode: "shared", chat_id: nil)
      {:ok, token} = Telegram.refresh_link_token(integration)

      assert_hashed("telegram_integrations", integration.id, "link_token", token)

      assert {:ok, _linked} = Telegram.handle_start_payload(token, "123456")
      assert raw("telegram_integrations", integration.id, "link_token_hash") == nil
    end
  end

  describe "tokens shown again, encrypted and looked up by hash" do
    test "a poll's voting link" do
      user = insert(:user)

      {:ok, poll} =
        %PollSchema{}
        |> PollSchema.creation_changeset(%{
          user_id: user.id,
          title: "Team sync",
          duration_minutes: 30,
          timezone: "Etc/UTC"
        })
        |> Repo.insert()

      assert_encrypted_and_hashed("polls", poll.id, "token", poll.token)
      assert {:ok, %{id: id}} = Polls.get_poll_for_voting(poll.token)
      assert id == poll.id
    end

    test "a poll participant's link, handed back when they register again" do
      poll = insert(:poll)
      attrs = %{"name" => "Ada", "email" => "ada@example.com"}

      {:ok, participant} = Voting.register_participant(poll, attrs)

      assert_encrypted_and_hashed("poll_participants", participant.id, "token", participant.token)
      assert Voting.get_participant(poll, participant.token).id == participant.id

      assert {:ok, again} = Voting.register_participant(poll, attrs)
      assert again.token == participant.token
    end

    test "a guest's RSVP token" do
      meeting = insert(:meeting)
      {:ok, guest} = GuestQueries.insert_guest(%{meeting_id: meeting.id, email: "g@example.com"})

      assert_encrypted_and_hashed("meeting_guests", guest.id, "rsvp_token", guest.rsvp_token)
      assert {:ok, %{id: id}} = GuestQueries.get_by_token(guest.rsvp_token)
      assert id == guest.id
    end

    test "a free/busy feed token, cleared with the feed" do
      profile = insert(:profile)
      {:ok, enabled} = FreeBusy.enable_feed(profile)

      assert_encrypted_and_hashed(
        "profiles",
        profile.id,
        "freebusy_token",
        enabled.freebusy_token
      )

      assert {:ok, %{id: id}} = FreeBusy.get_profile_by_token(enabled.freebusy_token)
      assert id == profile.id

      {:ok, _disabled} = FreeBusy.disable_feed(enabled)
      assert raw("profiles", profile.id, "freebusy_token_hash") == nil
      assert {:error, :not_found} = FreeBusy.get_profile_by_token(enabled.freebusy_token)
    end
  end

  # The plain column the value used to live in stays empty, and the encrypted
  # one opens to the value without containing it.
  defp assert_encrypted(table, id, column, value) do
    assert byte_size(value) > 0
    assert raw(table, id, column) == nil

    ciphertext = raw(table, id, "#{column}_encrypted")
    refute ciphertext =~ value
    assert Encryption.decrypt(ciphertext) == value
  end

  defp assert_encrypted_and_hashed(table, id, column, value) do
    assert_encrypted(table, id, column, value)
    assert raw(table, id, "#{column}_hash") == Token.hash_token(value)
  end

  # The plain column stays empty, and the hash column holds the token's hash.
  defp assert_hashed(table, id, column, token) do
    assert byte_size(token) > 0
    assert raw(table, id, column) == nil
    assert raw(table, id, "#{column}_hash") == Token.hash_token(token)
  end

  defp raw(table, id, column) do
    %{rows: [[value]]} =
      Repo.query!("SELECT #{column} FROM #{table} WHERE id = $1", [dump_id(id)])

    value
  end

  # Postgrex takes a UUID as its 16 raw bytes.
  defp dump_id(id) when is_integer(id), do: id
  defp dump_id(id), do: UUID.dump!(id)
end
