defmodule Tymeslot.Integrations.Video.RoomCreationErrorQueriesTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :queries

  alias Ecto.Changeset
  alias Tymeslot.Integrations.Video.RoomCreationErrorQueries

  describe "the error and its email" do
    test "a refusal is recorded once with the time it was first seen, and cleared" do
      integration = insert(:video_integration, provider: "nextcloud_talk")

      assert :ok =
               RoomCreationErrorQueries.record(
                 integration.id,
                 :password_required
               )

      recorded = Repo.reload!(integration)
      assert recorded.room_creation_error == :password_required
      assert %DateTime{} = since = recorded.room_creation_error_since

      Repo.update!(
        Changeset.change(recorded, room_creation_error_since: ~U[2026-01-01 00:00:00Z])
      )

      RoomCreationErrorQueries.record(integration.id, :password_required)
      assert Repo.reload!(integration).room_creation_error_since == ~U[2026-01-01 00:00:00Z]

      RoomCreationErrorQueries.record(integration.id, :talk_not_allowed)
      changed = Repo.reload!(integration)
      assert changed.room_creation_error == :talk_not_allowed
      refute changed.room_creation_error_since == ~U[2026-01-01 00:00:00Z]
      assert DateTime.compare(changed.room_creation_error_since, since) != :lt

      assert :ok = RoomCreationErrorQueries.clear(integration.id)

      assert %{room_creation_error: nil, room_creation_error_since: nil} =
               Repo.reload!(integration)
    end

    test "each code's email is claimed by exactly one caller, per integration" do
      integration = insert(:video_integration, provider: "nextcloud_talk")

      other =
        insert(:video_integration, provider: "nextcloud_talk", base_url: "https://b.example.com")

      assert claim(integration, :password_required)
      refute claim(integration, :password_required)
      assert claim(integration, :talk_not_allowed)
      assert claim(other, :password_required)

      # Clearing the refusal keeps the record of what the owner was told.
      RoomCreationErrorQueries.clear(integration.id)
      refute claim(integration, :password_required)

      assert %{"password_required" => _told_at, "talk_not_allowed" => _also_told_at} =
               Repo.reload!(integration).room_creation_error_notices
    end

    test "a code claimed long enough ago may be claimed again" do
      integration = insert(:video_integration, provider: "nextcloud_talk")
      assert claim(integration, :password_required)

      long_ago = DateTime.add(DateTime.utc_now(:second), -40, :day)

      integration
      |> Changeset.change(
        room_creation_error_notices: %{"password_required" => DateTime.to_iso8601(long_ago)}
      )
      |> Repo.update!()

      assert claim(integration, :password_required)
      refute claim(integration, :password_required)
    end

    test "a claim given back may be claimed again at once" do
      integration = insert(:video_integration, provider: "nextcloud_talk")
      assert claim(integration, :password_required)
      assert claim(integration, :talk_not_allowed)

      assert :ok =
               RoomCreationErrorQueries.release_notice(
                 integration.id,
                 :password_required
               )

      assert %{"talk_not_allowed" => _kept} =
               Repo.reload!(integration).room_creation_error_notices

      assert claim(integration, :password_required)
    end

    # A refusal of the same code inside the window is the one the owner already
    # knows about, whatever their integration's other codes have done since.
    defp claim(integration, code) do
      now = DateTime.utc_now(:second)

      RoomCreationErrorQueries.claim_notice(
        integration.id,
        code,
        now,
        DateTime.add(now, -30, :day)
      )
    end
  end
end
