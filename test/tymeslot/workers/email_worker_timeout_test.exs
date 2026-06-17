defmodule Tymeslot.Workers.EmailWorkerTimeoutTest do
  # async: false — the timeout is lowered via global application env, which must
  # not race with other email-worker tests running concurrently.
  use Tymeslot.DataCase, async: false

  @moduletag :workers

  use Oban.Testing, repo: Tymeslot.Repo

  import Mox
  import Tymeslot.Factory

  alias Tymeslot.Workers.EmailWorker

  setup :verify_on_exit!

  setup do
    original = Application.get_env(:tymeslot, :email_timeout_ms)
    Application.put_env(:tymeslot, :email_timeout_ms, 50)

    on_exit(fn ->
      if original do
        Application.put_env(:tymeslot, :email_timeout_ms, original)
      else
        Application.delete_env(:tymeslot, :email_timeout_ms)
      end
    end)

    :ok
  end

  describe "perform/1 — delivery timeout" do
    test "discards instead of retrying when a send outlives the timeout" do
      user = insert(:unverified_user)

      # Simulate an SMTP send that never returns within the timeout window. Such a
      # send may well have been delivered, so the job must discard rather than let
      # Oban re-send it (which is what produces duplicate emails). Blocking on a
      # message that never arrives keeps this deterministic — no sleep timing.
      stub(Tymeslot.EmailServiceMock, :send_email_verification, fn _user, _url ->
        receive do
          :never -> {:ok, :sent}
        end
      end)

      assert {:discard, "Email sending timed out"} =
               perform_job(EmailWorker, %{
                 "action" => "send_email_verification",
                 "user_id" => user.id,
                 "verification_url" => "https://example.com/verify"
               })
    end
  end
end
