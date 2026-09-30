defmodule Tymeslot.Integrations.Video.VideoIntegrationSchemaErrorTrackingTest do
  # async: false: ErrorTracker's `enabled` switch is global application env,
  # and the log handler sees events from every process.
  use Tymeslot.DataCase, async: false

  @moduletag :integrations
  @moduletag :video

  import ExUnit.CaptureLog
  import Tymeslot.ConfigTestHelpers

  alias ErrorTracker.Error
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Test.LogCapture

  @undecryptable :binary.copy(<<7>>, 30)

  setup do
    with_config(:error_tracker, enabled: true)
    :ok
  end

  test "an undecryptable credential is logged with its field and integration, redacted" do
    integration =
      insert(:video_integration, user: insert(:user), api_key_encrypted: @undecryptable)

    event =
      LogCapture.with_capture([level: :error], fn ->
        capture_log(fn ->
          assert VideoIntegrationSchema.decrypt_credentials(integration).api_key == nil
        end)

        LogCapture.await_log("Failed to decrypt video integration field")
      end)

    meta = LogCapture.user_metadata(event)
    assert meta.field == "api_key"
    assert meta.integration_id == integration.id
    assert meta.error == "RuntimeError"
    refute inspect(event) =~ inspect(@undecryptable)
  end

  # Decryption runs per field for every row a listing reads, so reporting
  # here would insert up to eight errors per integration on every dashboard
  # load after a lost key. `ReauthHandling.flag/2` records it once instead.
  test "undecryptable credentials are not recorded in error tracking" do
    integration =
      insert(:video_integration,
        user: insert(:user),
        api_key_encrypted: @undecryptable,
        access_token_encrypted: @undecryptable,
        client_secret_encrypted: @undecryptable
      )

    capture_log(fn ->
      decrypted = VideoIntegrationSchema.decrypt_credentials(integration)

      assert {decrypted.api_key, decrypted.access_token, decrypted.client_secret} ==
               {nil, nil, nil}
    end)

    assert Repo.all(Error) == []
  end
end
