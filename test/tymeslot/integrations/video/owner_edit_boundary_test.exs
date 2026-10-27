defmodule Tymeslot.Integrations.Video.OwnerEditBoundaryTest do
  @moduledoc """
  What an owner's edit can reach. The context is the boundary: an edit
  changes only what the owner may change, whatever attrs arrive, and a
  disconnected integration is gone from everything the owner does even
  though its row lives on until the cleanup worker has deleted its rooms.
  """

  use Tymeslot.DataCase, async: true
  @moduletag :integrations

  import Tymeslot.Factory

  alias Tymeslot.Integrations.Video
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema

  setup do
    user = insert(:user)

    {:ok, integration} =
      VideoIntegrationQueries.create(%{
        user_id: user.id,
        name: "Zoom",
        provider: "zoom",
        access_token: "stored-access",
        refresh_token: "stored-refresh",
        provider_account_id: "zoom-account",
        is_active: true
      })

    %{user: user, integration: integration}
  end

  test "an edit changes the name and nothing it may not change", %{
    user: user,
    integration: integration
  } do
    other = insert(:user)

    assert {:ok, _updated} =
             Video.update_integration(user.id, integration.id, %{
               "name" => "Renamed",
               "user_id" => other.id,
               "provider" => "mirotalk",
               "access_token" => "injected",
               "provider_account_id" => "someone-else",
               "is_active" => false
             })

    stored = VideoIntegrationSchema.decrypt_credentials(Repo.reload!(integration))

    assert stored.name == "Renamed"
    assert stored.user_id == user.id
    assert stored.provider == "zoom"
    assert stored.access_token == "stored-access"
    assert stored.provider_account_id == "zoom-account"
    assert stored.is_active
  end

  describe "a disconnected integration" do
    setup %{integration: integration} do
      {:ok, _soft} = VideoIntegrationQueries.soft_delete(integration)
      :ok
    end

    test "cannot be read, edited, toggled or tested by its owner", %{
      user: user,
      integration: integration
    } do
      assert {:error, :not_found} = Video.get_integration(user.id, integration.id)

      assert {:error, :not_found} =
               Video.update_integration(user.id, integration.id, %{"name" => "Back"})

      assert {:error, :not_found} = Video.toggle_integration(user.id, integration.id)
      assert {:error, :not_found} = Video.test_connection(user.id, integration.id)
    end

    test "is still reached by the cleanup worker's lookup", %{
      user: user,
      integration: integration
    } do
      assert {:ok, _row} = VideoIntegrationQueries.get_for_user(integration.id, user.id)
    end
  end
end
