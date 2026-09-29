defmodule Tymeslot.Integrations.Video.VideoIntegrationSchemaErrorTrackingTest do
  # async: false: ErrorTracker's `enabled` switch is global application env.
  use Tymeslot.DataCase, async: false

  @moduletag :integrations
  @moduletag :video

  import ExUnit.CaptureLog
  import Tymeslot.ConfigTestHelpers

  alias ErrorTracker.Error
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema

  test "a credential that no longer decrypts is recorded with the field and integration" do
    with_config(:error_tracker, enabled: true)

    integration =
      insert(:video_integration,
        user: insert(:user),
        api_key_encrypted: :binary.copy(<<7>>, 30)
      )

    capture_log(fn ->
      assert VideoIntegrationSchema.decrypt_credentials(integration).api_key == nil
    end)

    assert [%Error{kind: "Elixir.RuntimeError"} = error] =
             Error |> Repo.all() |> Repo.preload(:occurrences)

    assert [%{context: %{"field" => "api_key", "integration_id" => id}}] = error.occurrences
    assert id == integration.id
  end
end
