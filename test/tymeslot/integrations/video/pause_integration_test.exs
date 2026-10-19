defmodule Tymeslot.Integrations.Video.PauseIntegrationTest do
  @moduledoc """
  Pausing an unhealthy video integration is one-way: it never activates one,
  whatever the struct it is handed says.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :video
  @moduletag :integrations

  import Tymeslot.Factory

  alias Tymeslot.Integrations.Video
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema

  defp stored_active?(integration),
    do: Repo.get!(VideoIntegrationSchema, integration.id).is_active

  test "pauses an active integration read before an earlier pause wrote" do
    integration = insert(:video_integration, is_active: true)

    assert {:ok, _paused} = Video.pause_integration(%{integration | is_active: false})

    refute stored_active?(integration)
  end

  test "leaves a paused integration paused when handed a struct that says active" do
    integration = insert(:video_integration, is_active: false)

    assert {:ok, _paused} = Video.pause_integration(%{integration | is_active: true})

    refute stored_active?(integration)
  end
end
