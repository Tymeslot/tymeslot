defmodule Tymeslot.Auth.AccountDeletion.ExternalCleanupTest do
  use Tymeslot.DataCase, async: false

  @moduletag :auth
  @moduletag :integrations

  import ExUnit.CaptureLog
  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Auth.AccountDeletion.ExternalCleanup
  alias Tymeslot.Security.Encryption

  setup :verify_on_exit!

  test "one step failing outright does not stop the others" do
    user = insert(:user)

    insert(:calendar_integration,
      user: user,
      provider: "google",
      refresh_token_encrypted: Encryption.encrypt("calendar-refresh"),
      access_token_encrypted: Encryption.encrypt("calendar-access"),
      token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
    )

    insert(:slack_integration, user: user)
    test_pid = self()

    expect(Tymeslot.HTTPClientMock, :post, 2, fn url, _body, _headers, _opts ->
      send(test_pid, {:post, url})

      if String.contains?(url, "oauth2.googleapis.com"),
        do: raise("Google is down"),
        else: {:ok, %Req.Response{status: 200, body: ""}}
    end)

    assert ExternalCleanup.run(user) == :ok
    assert_received {:post, "https://oauth2.googleapis.com/revoke"}
    assert_received {:post, "https://slack.com/api/auth.revoke"}
  end

  test "a step returning an error is logged and does not raise" do
    log =
      capture_log(fn ->
        assert ExternalCleanup.run_step(:payments, 1, fn -> {:error, :boom} end) == :ok
      end)

    assert log =~ "cleanup step failed"
    assert log =~ "boom"
  end

  test "a step raising is logged and does not raise" do
    log =
      capture_log(fn ->
        assert ExternalCleanup.run_step(:calendars, 1, fn -> raise "calendars exploded" end) ==
                 :ok
      end)

    assert log =~ "cleanup step failed"
    assert log =~ "calendars exploded"
  end

  test "a step that exits or throws is logged and the next step still runs" do
    test_pid = self()

    steps = [
      calendars: fn -> exit(:lock_timeout) end,
      video: fn -> throw(:gave_up) end,
      slack: fn -> send(test_pid, :slack_ran) end
    ]

    log =
      capture_log(fn ->
        for {step, fun} <- steps, do: assert(ExternalCleanup.run_step(step, 1, fun) == :ok)
      end)

    assert_received :slack_ran
    assert log =~ "lock_timeout"
    assert log =~ "gave_up"
  end
end
