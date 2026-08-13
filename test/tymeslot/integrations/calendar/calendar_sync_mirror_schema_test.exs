defmodule Tymeslot.Integrations.Calendar.CalendarSyncMirrorSchemaTest do
  @moduledoc """
  The mirror mapping row: what it insists on before it will store a mapping,
  and what happens to it when the link or the target integration goes away.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :sync_links

  import Tymeslot.Factory

  alias Tymeslot.Integrations.Calendar.CalendarSyncMirrorSchema

  setup do
    link = insert(:calendar_sync_link)
    {:ok, link: link}
  end

  defp attrs(link, overrides \\ %{}) do
    Map.merge(
      %{
        sync_link_id: link.id,
        source_uid: "source-uid-1",
        target_integration_id: link.target_integration_id,
        target_uid: "tymeslot-mirror-1"
      },
      overrides
    )
  end

  describe "changeset/2" do
    test "accepts a minimal mapping and defaults to active", %{link: link} do
      assert {:ok, mirror} =
               %CalendarSyncMirrorSchema{}
               |> CalendarSyncMirrorSchema.changeset(attrs(link))
               |> Repo.insert()

      assert mirror.state == "active"
    end

    test "requires the link, both UIDs and the target integration", _ctx do
      changeset = CalendarSyncMirrorSchema.changeset(%CalendarSyncMirrorSchema{}, %{})

      errors = errors_on(changeset)
      assert "can't be blank" in errors.sync_link_id
      assert "can't be blank" in errors.source_uid
      assert "can't be blank" in errors.target_integration_id
      assert "can't be blank" in errors.target_uid
    end

    for state <- ~w(active pending_delete failed) do
      test "accepts the #{state} state", %{link: link} do
        changeset =
          CalendarSyncMirrorSchema.changeset(
            %CalendarSyncMirrorSchema{},
            attrs(link, %{state: unquote(state)})
          )

        assert changeset.valid?
      end
    end

    test "rejects a state the reconciliation sweep cannot interpret", %{link: link} do
      changeset =
        CalendarSyncMirrorSchema.changeset(
          %CalendarSyncMirrorSchema{},
          attrs(link, %{state: "confused"})
        )

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).state
    end
  end

  describe "database constraints" do
    test "one source event maps to at most one mirror per link", %{link: link} do
      assert {:ok, _mirror} =
               %CalendarSyncMirrorSchema{}
               |> CalendarSyncMirrorSchema.changeset(attrs(link))
               |> Repo.insert()

      assert {:error, changeset} =
               %CalendarSyncMirrorSchema{}
               |> CalendarSyncMirrorSchema.changeset(attrs(link, %{target_uid: "other"}))
               |> Repo.insert()

      assert "is already mirrored by this link" in errors_on(changeset).sync_link_id
    end

    test "the same source UID may be mirrored by a second link", %{link: link} do
      other_link = insert(:calendar_sync_link)

      assert {:ok, _mirror} =
               %CalendarSyncMirrorSchema{}
               |> CalendarSyncMirrorSchema.changeset(attrs(link))
               |> Repo.insert()

      assert {:ok, _second} =
               %CalendarSyncMirrorSchema{}
               |> CalendarSyncMirrorSchema.changeset(attrs(other_link))
               |> Repo.insert()
    end

    test "deleting the link cascades its mirrors away", %{link: link} do
      {:ok, mirror} =
        %CalendarSyncMirrorSchema{}
        |> CalendarSyncMirrorSchema.changeset(attrs(link))
        |> Repo.insert()

      Repo.delete!(link)

      refute Repo.get(CalendarSyncMirrorSchema, mirror.id)
    end

    test "deleting the target integration cascades its mirrors away", %{link: link} do
      {:ok, mirror} =
        %CalendarSyncMirrorSchema{}
        |> CalendarSyncMirrorSchema.changeset(attrs(link))
        |> Repo.insert()

      link |> Ecto.assoc(:target_integration) |> Repo.one!() |> Repo.delete!()

      refute Repo.get(CalendarSyncMirrorSchema, mirror.id)
    end

    test "a foreign key to a missing link is reported on the field", %{link: link} do
      assert {:error, changeset} =
               %CalendarSyncMirrorSchema{}
               |> CalendarSyncMirrorSchema.changeset(attrs(link, %{sync_link_id: 0}))
               |> Repo.insert()

      assert "does not exist" in errors_on(changeset).sync_link_id
    end
  end
end
