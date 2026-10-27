defmodule Tymeslot.Slack.TokenRevocationTest do
  use Tymeslot.DataCase, async: false

  @moduletag :slack
  @moduletag :integrations

  import ExUnit.CaptureLog
  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Security.Encryption
  alias Tymeslot.Slack
  alias Tymeslot.Slack.API
  alias Tymeslot.Test.LogCapture

  setup :verify_on_exit!

  describe "API.revoke_token/1" do
    test "calls auth.revoke with the bot token" do
      expect(Tymeslot.HTTPClientMock, :post, fn url, _body, headers, _opts ->
        assert url == "https://slack.com/api/auth.revoke"
        assert {"authorization", "Bearer xoxb-1"} in headers
        {:ok, %Req.Response{status: 200, body: %{"ok" => true, "revoked" => true}}}
      end)

      assert API.revoke_token("xoxb-1") == :ok
    end

    test "a token Slack already treats as dead counts as revoked" do
      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: %{"ok" => false, "error" => "token_revoked"}}}
      end)

      assert API.revoke_token("xoxb-1") == :ok
    end

    test "any other Slack error is returned" do
      expect(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: %{"ok" => false, "error" => "fatal_error"}}}
      end)

      assert {:error, {:slack_error, "fatal_error", _body}} = API.revoke_token("xoxb-1")
    end
  end

  describe "Slack.revoke_tokens_for_user/1" do
    test "revokes the OAuth workspace and skips a webhook-only one" do
      user = insert(:user)
      insert(:slack_integration, user: user)
      insert(:slack_integration, user: user, app_mode: "webhook_url", bot_token_encrypted: nil)

      expect(Tymeslot.HTTPClientMock, :post, 1, fn "https://slack.com/api/auth.revoke",
                                                   _body,
                                                   headers,
                                                   _opts ->
        assert {"authorization", "Bearer xoxb-test-token"} in headers
        {:ok, %Req.Response{status: 200, body: %{"ok" => true}}}
      end)

      assert Slack.revoke_tokens_for_user(user.id) == :ok
    end

    test "keeps the token of a workspace another account has also connected" do
      user = insert(:user)
      other = insert(:user)
      insert(:slack_integration, user: user, team_id: "T-SHARED")
      insert(:slack_integration, user: other, team_id: "T-SHARED")

      insert(:slack_integration,
        user: user,
        team_id: "T-OWN",
        bot_token_encrypted: Encryption.encrypt("xoxb-own")
      )

      expect(Tymeslot.HTTPClientMock, :post, 1, fn "https://slack.com/api/auth.revoke",
                                                   _body,
                                                   headers,
                                                   _opts ->
        assert {"authorization", "Bearer xoxb-own"} in headers
        {:ok, %Req.Response{status: 200, body: %{"ok" => true}}}
      end)

      assert Slack.revoke_tokens_for_user(user.id) == :ok
    end

    test "revokes a shared workspace once the other account holds no token for it" do
      user = insert(:user)
      other = insert(:user)
      insert(:slack_integration, user: user, team_id: "T-SHARED")

      insert(:slack_integration,
        user: other,
        team_id: "T-SHARED",
        app_mode: "webhook_url",
        bot_token_encrypted: nil
      )

      expect(Tymeslot.HTTPClientMock, :post, 1, fn "https://slack.com/api/auth.revoke",
                                                   _body,
                                                   _headers,
                                                   _opts ->
        {:ok, %Req.Response{status: 200, body: %{"ok" => true}}}
      end)

      assert Slack.revoke_tokens_for_user(user.id) == :ok
    end

    test "a failing or unreadable integration does not stop the others" do
      user = insert(:user)
      insert(:slack_integration, user: user, bot_token_encrypted: Encryption.encrypt("xoxb-a"))

      # Long enough to be treated as ciphertext, but not decryptable: raises.
      unreadable =
        insert(:slack_integration, user: user, bot_token_encrypted: :crypto.strong_rand_bytes(64))

      insert(:slack_integration, user: user, bot_token_encrypted: Encryption.encrypt("xoxb-c"))

      test_pid = self()

      stub(Tymeslot.HTTPClientMock, :post, fn _url, _body, headers, _opts ->
        {"authorization", "Bearer " <> token} = List.keyfind(headers, "authorization", 0)
        send(test_pid, {:revoked, token})

        if token == "xoxb-a" do
          {:error, :timeout}
        else
          {:ok, %Req.Response{status: 200, body: %{"ok" => true}}}
        end
      end)

      LogCapture.attach(level: :warning)
      log = capture_log(fn -> assert Slack.revoke_tokens_for_user(user.id) == :ok end)

      assert_received {:revoked, "xoxb-a"}
      assert_received {:revoked, "xoxb-c"}
      assert log =~ "Slack token revocation failed"

      # The unreadable one raised: its log names it and the exception module.
      assert Enum.any?(LogCapture.drain(), fn event ->
               meta = LogCapture.user_metadata(event)
               meta[:integration_id] == unreadable.id and meta[:exception] == "RuntimeError"
             end)
    end
  end
end
